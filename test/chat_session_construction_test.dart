// ChatSession construction/open (V1_SPEC §3/§4): open(history) is the
// constructor — stale-status normalisation, invariant checks, Idle start,
// and the loud ArgumentError configuration guards.
import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

void main() {
  test('opens in Idle with an empty conversation when history is omitted', () {
    final session = makeSession(backend: FakeChatBackend());
    expect(session.state, const ConversationState.idle());
    expect(session.snapshot.messages, isEmpty);
    expect(session.botProfile, plainProfile);
  });

  test('normalises stale in-flight statuses on open, keeping keys', () {
    final session = makeSession(
      backend: FakeChatBackend(),
      history: Conversation(
        messages: [
          userMessage('u-1', 'hi'),
          assistantMessage('a-1', 'hello'),
          userMessage('u-2', 'stuck', status: MessageStatus.sending),
          assistantMessage(
            'a-2',
            'half a rep',
            status: MessageStatus.streaming,
          ),
        ],
      ),
    );
    final messages = session.snapshot.messages;
    expect(messages[2].status, MessageStatus.failed);
    expect(messages[2].attemptKey, 'key-u-2', reason: 'the key survives');
    expect(messages[3].status, MessageStatus.interrupted);
    expect(messages[3].attemptKey, 'key-a-2');
    // Untouched messages stay untouched; the session opens in Idle.
    expect(messages[0].status, MessageStatus.sent);
    expect(messages[1].status, MessageStatus.complete);
    expect(session.state, const ConversationState.idle());
  });

  test(
    'invalid history is not repaired beyond the normative normalisation',
    () {
      // Duplicate ids fail the invariant check loudly.
      expect(
        () => makeSession(
          backend: FakeChatBackend(),
          history: Conversation(
            messages: [userMessage('u-1', 'a'), userMessage('u-1', 'b')],
          ),
        ),
        throwsFormatException,
      );
      // A complete assistant Message with an unmatched trailing toolCall is
      // invalid — streaming would have been normalised, complete never is.
      expect(
        () => makeSession(
          backend: FakeChatBackend(),
          history: Conversation(
            messages: [
              userMessage('u-1', 'a'),
              assistantMessage(
                'a-1',
                '',
                parts: const [ContentPart.toolCall('c1', 'searchNotes', {})],
              ),
            ],
          ),
        ),
        throwsFormatException,
      );
      // A streaming one is exactly the legal stale shape: normalised, kept.
      final session = makeSession(
        backend: FakeChatBackend(),
        history: Conversation(
          messages: [
            userMessage('u-1', 'a'),
            assistantMessage(
              'a-1',
              '',
              status: MessageStatus.streaming,
              parts: const [
                ContentPart.text('let me check'),
                ContentPart.toolCall('c1', 'searchNotes', {}),
              ],
            ),
          ],
        ),
      );
      expect(session.snapshot.messages.last.status, MessageStatus.interrupted);
    },
  );

  test('a history with schemaVersion != 1 is rejected, never silently '
      'normalised; the snapshot keeps schemaVersion 1', () {
    expect(
      () => makeSession(
        backend: FakeChatBackend(),
        history: Conversation(
          schemaVersion: 2,
          messages: [userMessage('u-1', 'hi')],
        ),
      ),
      throwsArgumentError,
    );
    final session = makeSession(
      backend: FakeChatBackend(),
      history: Conversation(messages: [userMessage('u-1', 'hi')]),
    );
    expect(session.snapshot.schemaVersion, 1);
  });

  group('configuration guards (ArgumentError, V1_SPEC §3/§5)', () {
    test('the exact ImageSendOptions bounds are accepted: 1/1/1 and '
        'jpegQuality 100', () {
      expect(
        () => makeSession(
          backend: FakeChatBackend(),
          imageOptions: const ImageSendOptions(
            maxLongEdge: 1,
            jpegQuality: 1,
            maxImagesPerMessage: 1,
          ),
        ),
        returnsNormally,
      );
      expect(
        () => makeSession(
          backend: FakeChatBackend(),
          imageOptions: const ImageSendOptions(jpegQuality: 100),
        ),
        returnsNormally,
      );
    });

    test('invalid numeric configuration throws', () {
      final backend = FakeChatBackend();
      expect(
        () => makeSession(backend: backend, maxToolTurns: 0),
        throwsArgumentError,
      );
      expect(
        () => makeSession(backend: backend, retryDeadline: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => makeSession(backend: backend, trimBudget: 0),
        throwsArgumentError,
      );
      expect(
        () => makeSession(
          backend: backend,
          imageOptions: const ImageSendOptions(maxImagesPerMessage: 0),
        ),
        throwsArgumentError,
      );
      expect(
        () => makeSession(
          backend: backend,
          imageOptions: const ImageSendOptions(maxLongEdge: 0),
        ),
        throwsArgumentError,
      );
      expect(
        () => makeSession(
          backend: backend,
          imageOptions: const ImageSendOptions(jpegQuality: 0),
        ),
        throwsArgumentError,
      );
      expect(
        () => makeSession(
          backend: backend,
          imageOptions: const ImageSendOptions(jpegQuality: 101),
        ),
        throwsArgumentError,
      );
    });

    const searchTool = Tool(
      name: 'searchNotes',
      description: 'd',
      parameters: {
        'type': 'object',
        'properties': <String, dynamic>{},
        'required': <String>[],
        'additionalProperties': false,
      },
    );

    test('tools without a resolver throw', () {
      expect(
        () => makeSession(
          backend: FakeChatBackend(),
          botProfile: const BotProfile(
            id: 'p',
            systemPrompt: 's',
            tools: [searchTool],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('duplicate/invalid names and non-v1 schemas throw', () {
      Future<ToolResult> resolver(ToolCall call) async =>
          const ToolResult(content: '', isError: false);
      expect(
        () => makeSession(
          backend: FakeChatBackend(),
          onToolCall: resolver,
          botProfile: const BotProfile(
            id: 'p',
            systemPrompt: 's',
            tools: [searchTool, searchTool],
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => makeSession(
          backend: FakeChatBackend(),
          onToolCall: resolver,
          botProfile: const BotProfile(
            id: 'p',
            systemPrompt: 's',
            tools: [Tool(name: 'bad name', description: 'd', parameters: {})],
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => makeSession(
          backend: FakeChatBackend(),
          onToolCall: resolver,
          botProfile: const BotProfile(
            id: 'p',
            systemPrompt: 's',
            tools: [
              Tool(
                name: 'searchNotes',
                description: 'd',
                parameters: {'type': 'object', r'$ref': '#/x'},
              ),
            ],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('botProfile setter validates first and keeps the old profile', () {
      final session = makeSession(backend: FakeChatBackend());
      expect(
        () => session.botProfile = const BotProfile(
          id: 'p2',
          systemPrompt: 's2',
          tools: [searchTool], // no resolver on this session
        ),
        throwsArgumentError,
      );
      expect(session.botProfile, plainProfile, reason: 'old profile kept');

      const next = BotProfile(id: 'p2', systemPrompt: 's2', tools: []);
      session.botProfile = next;
      expect(session.botProfile, next);
    });
  });
}
