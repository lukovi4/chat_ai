// ChatRequest → `response.create` payload (tests 5, 6, 7, 9, 12, 13 of the
// task's minimum set). Pure mapper tests — no transport involved.

import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_openai_realtime/src/realtime_request_translator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Message message(
  MessageRole role,
  List<ContentPart> parts, {
  String id = 'message-1',
  String? attemptKey = 'attempt-1',
  MessageStatus status = MessageStatus.complete,
}) => Message(
  id: id,
  role: role,
  parts: parts,
  status: status,
  attemptKey: attemptKey,
  createdAt: DateTime.utc(2026, 7, 16, 12),
);

Map<String, dynamic> responseOf(Map<String, dynamic> event) =>
    event['response'] as Map<String, dynamic>;

List<dynamic> inputOf(Map<String, dynamic> event) =>
    responseOf(event)['input'] as List<dynamic>;

void main() {
  test('payload is exactly one stateless text-only response.create', () {
    final event = buildResponseCreateEvent(chatRequest(system: 'SYSTEM'));
    expect(event['type'], 'response.create');
    final response = responseOf(event);
    expect(response['conversation'], 'none');
    expect(response['output_modalities'], ['text']);
    expect(response['instructions'], 'SYSTEM');
    expect(response['parallel_tool_calls'], false);
    expect(response.containsKey('tools'), isFalse); // omitted when empty
    expect(response.containsKey('model'), isFalse);
    expect(response.containsKey('metadata'), isFalse);
    expect(response.containsKey('audio'), isFalse);
    expect(response.containsKey('previous_response_id'), isFalse);
  });

  test('JPEG maps to an input_image data URL (test 5)', () {
    final bytes = jpegBytes();
    final event = buildResponseCreateEvent(
      chatRequest(
        messages: [
          message(MessageRole.user, [
            ContentPart.text('look'),
            ContentPart.image(bytes),
          ]),
        ],
      ),
    );
    final input = inputOf(event);
    final content =
        (input.single as Map<String, dynamic>)['content'] as List<dynamic>;
    expect(content, [
      {'type': 'input_text', 'text': 'look'},
      {
        'type': 'input_image',
        'image_url': 'data:image/jpeg;base64,${base64Encode(bytes)}',
      },
    ]);
  });

  test('system/user/assistant keep the required semantics and order (test 6): '
      'persisted system Messages stay system input ahead of history', () {
    final event = buildResponseCreateEvent(
      chatRequest(
        messages: [
          message(MessageRole.user, [ContentPart.text('u1')], id: 'u1'),
          message(
            MessageRole.system,
            [ContentPart.text('s1'), ContentPart.text('s2')],
            id: 's1',
            attemptKey: null,
          ),
          message(MessageRole.assistant, [ContentPart.text('a1')], id: 'a1'),
          message(MessageRole.user, [ContentPart.text('u2')], id: 'u2'),
        ],
      ),
    );
    expect(inputOf(event), [
      {
        'type': 'message',
        'role': 'system',
        'content': [
          {'type': 'input_text', 'text': 's1\ns2'},
        ],
      },
      {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': 'u1'},
        ],
      },
      {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': 'a1'},
        ],
      },
      {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': 'u2'},
        ],
      },
    ]);
  });

  test('tool declarations map to Realtime function tools (test 7)', () {
    const tool = Tool(
      name: 'get_weather',
      description: 'Returns the weather.',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'city': <String, dynamic>{'type': 'string'},
        },
        'required': ['city'],
      },
    );
    final event = buildResponseCreateEvent(chatRequest(tools: const [tool]));
    final response = responseOf(event);
    expect(response['tools'], [
      {
        'type': 'function',
        'name': 'get_weather',
        'description': 'Returns the weather.',
        'parameters': tool.parameters,
      },
    ]);
    expect(response['parallel_tool_calls'], false);
  });

  test('prior ToolCallPart/ToolResultPart map to function_call and '
      'function_call_output of the next stateless input (test 9)', () {
    final event = buildResponseCreateEvent(
      chatRequest(
        messages: [
          message(MessageRole.user, [ContentPart.text('weather?')], id: 'u1'),
          message(MessageRole.assistant, [
            ContentPart.text('Checking.'),
            ContentPart.toolCall('call_7', 'get_weather', <String, dynamic>{
              'city': 'Kyiv',
            }),
            ContentPart.toolResult('call_7', 'sunny', false),
            ContentPart.text('It is sunny.'),
          ], id: 'a1'),
        ],
      ),
    );
    final input = inputOf(event);
    expect(input, hasLength(5));
    expect(input[1], {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': 'Checking.'},
      ],
    });
    expect(input[2], {
      'type': 'function_call',
      'call_id': 'call_7',
      'name': 'get_weather',
      'arguments': '{"city":"Kyiv"}',
    });
    // Tool result output stays wire-compatible with the base package's
    // server translator: {"content": <string>, "isError": <bool>}.
    expect(input[3], {
      'type': 'function_call_output',
      'call_id': 'call_7',
      'output': '{"content":"sunny","isError":false}',
    });
    expect(input[4], {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': 'It is sunny.'},
      ],
    });
  });

  test('ProviderOpaquePart never reaches the payload (test 12)', () {
    final opaqueBytes = Uint8List.fromList(utf8.encode('{"secret":"state"}'));
    final event = buildResponseCreateEvent(
      chatRequest(
        messages: [
          message(MessageRole.user, [ContentPart.text('hi')], id: 'u1'),
          message(MessageRole.assistant, [
            ContentPart.providerOpaque('openai', opaqueBytes),
            ContentPart.text('hello'),
            ContentPart.providerOpaque('anthropic', opaqueBytes),
          ], id: 'a1'),
        ],
      ),
    );
    final payload = jsonEncode(event);
    expect(payload, isNot(contains('providerOpaque')));
    expect(payload, isNot(contains(base64Encode(opaqueBytes))));
    expect(payload, isNot(contains('secret')));
    expect(inputOf(event), hasLength(2)); // user item + assistant text item
  });

  test('client bookkeeping never reaches the payload (test 13)', () {
    final event = buildResponseCreateEvent(
      chatRequest(
        botId: 'bot-payload-check',
        idempotencyKey: 'idempotency-payload-check',
        messages: [
          message(
            MessageRole.user,
            [ContentPart.text('hi')],
            id: 'message-id-payload-check',
            attemptKey: 'attempt-payload-check',
          ),
        ],
      ),
    );
    final payload = jsonEncode(event);
    expect(payload, isNot(contains('bot-payload-check')));
    expect(payload, isNot(contains('idempotency-payload-check')));
    expect(payload, isNot(contains('message-id-payload-check')));
    expect(payload, isNot(contains('attempt-payload-check')));
    expect(payload, isNot(contains('wireVersion')));
    expect(payload, isNot(contains('createdAt')));
    expect(payload, isNot(contains('2026-07-16')));
    expect(payload, isNot(contains('"status"')));
  });
}
