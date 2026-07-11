// Freezed value semantics (equality / copyWith / defaults) and the exact enum
// catalogues of the foundation models (V1_SPEC §5).
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final createdAt = DateTime.utc(2026, 7, 10, 9, 15);

  group('value equality', () {
    test('Message: equal by content, deep over parts', () {
      Message build() => Message(
        id: 'm-1',
        role: MessageRole.assistant,
        parts: [
          const ContentPart.text('hello'),
          ContentPart.providerOpaque('openai', Uint8List.fromList([1, 2])),
        ],
        status: MessageStatus.complete,
        attemptKey: 'k-1',
        createdAt: createdAt,
      );
      expect(build(), build());
      expect(build().hashCode, build().hashCode);
    });

    test('ContentPart: bytes compare by content, not identity', () {
      expect(
        ContentPart.image(Uint8List.fromList([1, 2, 3])),
        ContentPart.image(Uint8List.fromList([1, 2, 3])),
      );
      expect(
        ContentPart.image(Uint8List.fromList([1, 2, 3])),
        isNot(ContentPart.image(Uint8List.fromList([1, 2, 4]))),
      );
    });

    test('ContentPart: toolCall args compare deeply', () {
      expect(
        const ContentPart.toolCall('c1', 'n', {
          'a': 1,
          'b': [1, 2],
        }),
        const ContentPart.toolCall('c1', 'n', {
          'a': 1,
          'b': [1, 2],
        }),
      );
      expect(
        const ContentPart.toolCall('c1', 'n', {'a': 1}),
        isNot(const ContentPart.toolCall('c1', 'n', {'a': 2})),
      );
    });

    test('the five part cases are distinct types under one sealed root', () {
      final parts = <ContentPart>[
        const ContentPart.text('t'),
        ContentPart.image(Uint8List(0)),
        const ContentPart.toolCall('c', 'n', {}),
        const ContentPart.toolResult('c', 'ok', false),
        ContentPart.providerOpaque('anthropic', Uint8List(0)),
      ];
      expect(parts[0], isA<TextPart>());
      expect(parts[1], isA<ImagePart>());
      expect(parts[2], isA<ToolCallPart>());
      expect(parts[3], isA<ToolResultPart>());
      expect(parts[4], isA<ProviderOpaquePart>());
    });

    test('Conversation: schemaVersion defaults to 1', () {
      const conversation = Conversation(messages: []);
      expect(conversation.schemaVersion, 1);
      expect(conversation, const Conversation(messages: []));
    });

    test(
      'Usage / BotProfile / Tool / ToolCall / ToolResult are value objects',
      () {
        expect(
          const Usage(inputTokens: 1, outputTokens: 2, usageRaw: {'t': 'x'}),
          const Usage(inputTokens: 1, outputTokens: 2, usageRaw: {'t': 'x'}),
        );
        expect(const Usage(inputTokens: 1, outputTokens: 2).usageRaw, isNull);
        expect(
          const BotProfile(id: 'premium', systemPrompt: 'be kind', tools: []),
          const BotProfile(id: 'premium', systemPrompt: 'be kind', tools: []),
        );
        expect(
          const Tool(name: 'searchNotes', description: 'd', parameters: {}),
          const Tool(name: 'searchNotes', description: 'd', parameters: {}),
        );
        expect(
          const ToolCall(id: 'c1', name: 'searchNotes', args: {'q': 'x'}),
          const ToolCall(id: 'c1', name: 'searchNotes', args: {'q': 'x'}),
        );
        expect(
          const ToolResult(content: '3 notes', isError: false),
          const ToolResult(content: '3 notes', isError: false),
        );
      },
    );
  });

  group('copyWith', () {
    test('Message.copyWith replaces a field, keeps the rest', () {
      final original = Message(
        id: 'm-1',
        role: MessageRole.user,
        parts: const [ContentPart.text('hi')],
        status: MessageStatus.sending,
        attemptKey: 'k-1',
        createdAt: createdAt,
      );
      final sent = original.copyWith(status: MessageStatus.sent);
      expect(sent.status, MessageStatus.sent);
      expect(sent.id, original.id);
      expect(sent.attemptKey, original.attemptKey);
      expect(sent, isNot(original));
    });

    test('ImageSendOptions.copyWith keeps the untouched defaults', () {
      const options = ImageSendOptions();
      final lowered = options.copyWith(maxImagesPerMessage: 1);
      expect(lowered.maxImagesPerMessage, 1);
      expect(lowered.maxLongEdge, 2048);
      expect(lowered.jpegQuality, 85);
    });
  });

  group('defaults and catalogues', () {
    test('ImageSendOptions defaults are 2048 / 85 / 4 (V1_SPEC §11)', () {
      const options = ImageSendOptions();
      expect(options.maxLongEdge, 2048);
      expect(options.jpegQuality, 85);
      expect(options.maxImagesPerMessage, 4);
    });

    test('FailureCause is the closed 10-code catalogue, in order', () {
      expect(FailureCause.values.map((cause) => cause.name), [
        'auth',
        'entitlement',
        'quota',
        'rate',
        'overloaded',
        'contentFilter',
        'contextTooLong',
        'network',
        'upstream',
        'toolLoopLimit',
      ]);
    });

    test('FailurePhase is sending | streaming', () {
      expect(FailurePhase.values.map((phase) => phase.name), [
        'sending',
        'streaming',
      ]);
    });

    test('MessageRole and MessageStatus carry the exact wire names', () {
      expect(MessageRole.values.map((role) => role.name), [
        'user',
        'assistant',
        'system',
      ]);
      expect(MessageStatus.values.map((status) => status.name), [
        'sending',
        'sent',
        'failed',
        'streaming',
        'complete',
        'interrupted',
      ]);
    });
  });

  group('ConversationState (ephemeral union)', () {
    test('cases are value-equal and pattern-matchable', () {
      expect(const ConversationState.idle(), const ConversationState.idle());
      expect(
        const ConversationState.done(
          usage: Usage(inputTokens: 1, outputTokens: 2),
        ),
        const ConversationState.done(
          usage: Usage(inputTokens: 1, outputTokens: 2),
        ),
      );
      expect(
        const ConversationState.failed(
          FailureCause.rate,
          FailurePhase.sending,
          developerDetail: '429',
        ),
        const ConversationState.failed(
          FailureCause.rate,
          FailurePhase.sending,
          developerDetail: '429',
        ),
      );
      expect(
        const ConversationState.idle(),
        isNot(const ConversationState.sending()),
      );
    });

    test('an exhaustive switch covers all seven phases', () {
      String label(ConversationState state) => switch (state) {
        Idle() => 'idle',
        Sending() => 'sending',
        AwaitingTool(:final call) => 'awaitingTool:${call.name}',
        Streaming() => 'streaming',
        Done(:final usage) => 'done:${usage?.outputTokens}',
        Failed(:final cause, :final phase) =>
          'failed:${cause.name}:${phase.name}',
        Cancelled() => 'cancelled',
      };

      expect(label(const ConversationState.idle()), 'idle');
      expect(label(const ConversationState.sending()), 'sending');
      expect(
        label(
          const ConversationState.awaitingTool(
            ToolCall(id: 'c1', name: 'searchNotes', args: {}),
          ),
        ),
        'awaitingTool:searchNotes',
      );
      expect(label(const ConversationState.streaming()), 'streaming');
      expect(
        label(
          const ConversationState.done(
            usage: Usage(inputTokens: 1, outputTokens: 9),
          ),
        ),
        'done:9',
      );
      expect(label(const ConversationState.done()), 'done:null');
      expect(
        label(
          const ConversationState.failed(
            FailureCause.network,
            FailurePhase.streaming,
          ),
        ),
        'failed:network:streaming',
      );
      expect(label(const ConversationState.cancelled()), 'cancelled');
    });
  });
}
