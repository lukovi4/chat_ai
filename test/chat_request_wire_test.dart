// The internal wire-encoder ChatRequest → JSON request body (V1_SPEC §6
// "Request (client → proxy)"; SERVER-CONTRACT §5): exact top-level form,
// messages via the storage JSON of Message, tools omitted when empty,
// idempotencyKey never in the body, byte-identical repeat encoding.
// Imports the internal file directly — encodeChatRequestBody is NOT exported
// from package:chat_ai/chat_ai.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai/src/backend/chat_request_wire.dart';
import 'package:flutter_test/flutter_test.dart';

final Uint8List imageBytes = Uint8List.fromList([0, 1, 255, 128]);
final Uint8List opaqueBytes = Uint8List.fromList([1, 2, 3]);

/// One full ChatRequest exercising every encoded field at once: all three
/// roles, every ContentPart kind, unicode, an attemptKey-less system
/// Message and a Tool whose JSON Schema carries an unknown extension field.
final ChatRequest fullRequest = ChatRequest(
  botId: 'premium',
  system: 'Ты — ассистент. π€😀',
  messages: [
    Message(
      id: 'm1',
      role: MessageRole.system,
      parts: const [ContentPart.text('correction')],
      status: MessageStatus.complete,
      createdAt: DateTime.utc(2026, 7, 11, 12),
    ),
    Message(
      id: 'm2',
      role: MessageRole.user,
      parts: [
        const ContentPart.text('Что на фото? 😀'),
        ContentPart.image(imageBytes),
      ],
      status: MessageStatus.sent,
      attemptKey: 'attempt-1',
      createdAt: DateTime.utc(2026, 7, 11, 12, 0, 1),
    ),
    Message(
      id: 'm3',
      role: MessageRole.assistant,
      parts: [
        const ContentPart.text('Смотрю.'),
        const ContentPart.toolCall('call_1', 'searchNotes', {'q': 'фото'}),
        const ContentPart.toolResult('call_1', 'нет заметок', false),
        ContentPart.providerOpaque('openai', opaqueBytes),
        const ContentPart.text('Готово.'),
      ],
      status: MessageStatus.complete,
      attemptKey: 'attempt-2',
      createdAt: DateTime.utc(2026, 7, 11, 12, 0, 2),
    ),
  ],
  tools: const [
    Tool(
      name: 'searchNotes',
      description: 'Search the user notes',
      parameters: {
        'type': 'object',
        'properties': {
          'q': {'type': 'string'},
        },
        'required': ['q'],
        'x-unknown-extension': true,
      },
    ),
  ],
  idempotencyKey: 'idem-123',
);

Map<String, dynamic> decodeBody(ChatRequest request) =>
    jsonDecode(encodeChatRequestBody(request)) as Map<String, dynamic>;

void main() {
  group('exact body form', () {
    test(
      'top level is wireVersion/botId/system/messages/tools; messages are '
      'the storage JSON of Message; tools are name/description/parameters',
      () {
        expect(decodeBody(fullRequest), {
          'wireVersion': 1,
          'botId': 'premium',
          'system': 'Ты — ассистент. π€😀',
          'messages': [
            for (final message in fullRequest.messages) message.toJson(),
          ],
          'tools': [
            {
              'name': 'searchNotes',
              'description': 'Search the user notes',
              'parameters': {
                'type': 'object',
                'properties': {
                  'q': {'type': 'string'},
                },
                'required': ['q'],
                // An unknown JSON Schema field passes through as-is —
                // the encoder never validates the schema.
                'x-unknown-extension': true,
              },
            },
          ],
        });
      },
    );

    test('client-only Message fields and part JSON (incl. base64) are pinned '
        'byte-exact in the body', () {
      final messages = decodeBody(fullRequest)['messages'] as List<dynamic>;
      final user = messages[1] as Map<String, dynamic>;
      expect(user['id'], 'm2');
      expect(user['status'], 'sent');
      expect(user['attemptKey'], 'attempt-1');
      expect(user['createdAt'], '2026-07-11T12:00:01.000Z');
      expect((user['parts'] as List<dynamic>)[1], {
        'type': 'image',
        'mimeType': 'image/jpeg',
        'data': base64Encode(imageBytes),
      });

      final system = messages[0] as Map<String, dynamic>;
      expect(
        system.containsKey('attemptKey'),
        isFalse,
        reason: 'a null attemptKey stays omitted, as in storage JSON',
      );

      final assistantParts =
          (messages[2] as Map<String, dynamic>)['parts'] as List<dynamic>;
      expect(assistantParts[3], {
        'type': 'providerOpaque',
        'provider': 'openai',
        'data': base64Encode(opaqueBytes),
      });
    });

    test('unicode in system and text survives the JSON round-trip', () {
      final body = decodeBody(fullRequest);
      expect(body['system'], 'Ты — ассистент. π€😀');
      final userParts =
          ((body['messages'] as List<dynamic>)[1]
                  as Map<String, dynamic>)['parts']
              as List<dynamic>;
      expect((userParts[0] as Map<String, dynamic>)['text'], 'Что на фото? 😀');
    });
  });

  group('tools omission', () {
    test('an empty tools list omits the key entirely (never "tools":[])', () {
      final body = decodeBody(fullRequest.copyWith(tools: const []));
      expect(body.containsKey('tools'), isFalse);
      expect(body.keys.toSet(), {
        'wireVersion',
        'botId',
        'system',
        'messages',
      }, reason: 'nothing else appears at the top level');
    });
  });

  group('idempotencyKey', () {
    test('never appears in the body at any level', () {
      final raw = encodeChatRequestBody(fullRequest);
      expect(raw.contains('idempotencyKey'), isFalse);
      expect(
        raw.contains('idem-123'),
        isFalse,
        reason: 'the key value rides only in the Idempotency-Key header',
      );
    });
  });

  group('frozen serialized request (V1_SPEC §8)', () {
    test('two calls over the same unchanged request yield the identical '
        'string', () {
      expect(
        encodeChatRequestBody(fullRequest),
        encodeChatRequestBody(fullRequest),
      );
    });

    test('the result is compact valid JSON (standard jsonEncode form)', () {
      final raw = encodeChatRequestBody(fullRequest);
      final Object? decoded = jsonDecode(raw);
      expect(decoded, isA<Map<String, dynamic>>());
      expect(
        raw,
        jsonEncode(decoded),
        reason: 'compact standard encoding — no custom canonicalizer needed',
      );
    });
  });
}
