// The exact storage-JSON contract of V1_SPEC §5: shapes, discriminator, enum
// strings, base64, UTC timestamps, null-omission, and the read policy
// (unknown fields ignored; unknown type/role/status/schemaVersion rejected).
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final imageBytes = Uint8List.fromList([255, 216, 255, 0, 1]);
  final opaqueBytes = Uint8List.fromList([9, 8, 7]);
  final userCreatedAt = DateTime.utc(2026, 7, 10, 9, 15);
  final botCreatedAt = DateTime.utc(2026, 7, 10, 9, 15, 4);

  Conversation fullConversation() => Conversation(
    messages: [
      Message(
        id: 'u-1',
        role: MessageRole.user,
        parts: [
          const ContentPart.text("What's on this photo?"),
          ContentPart.image(imageBytes),
        ],
        status: MessageStatus.sent,
        attemptKey: 'key-u-1',
        createdAt: userCreatedAt,
      ),
      Message(
        id: 'a-1',
        role: MessageRole.assistant,
        parts: [
          const ContentPart.text('Let me check your notes.'),
          const ContentPart.toolCall('call_1', 'searchNotes', {
            'period': '2026-06',
          }),
          const ContentPart.toolResult('call_1', '3 notes found', false),
          ContentPart.providerOpaque('openai', opaqueBytes),
          const ContentPart.text('You noted this plant in June…'),
        ],
        status: MessageStatus.complete,
        attemptKey: 'key-a-1',
        createdAt: botCreatedAt,
      ),
      Message(
        id: 's-1',
        role: MessageRole.system,
        parts: [const ContentPart.text('The user renamed the plant.')],
        status: MessageStatus.complete,
        createdAt: botCreatedAt,
      ),
    ],
  );

  Map<String, dynamic> fullConversationJson() => {
    'schemaVersion': 1,
    'messages': [
      {
        'id': 'u-1',
        'role': 'user',
        'parts': [
          {'type': 'text', 'text': "What's on this photo?"},
          {
            'type': 'image',
            'mimeType': 'image/jpeg',
            'data': base64Encode(imageBytes),
          },
        ],
        'status': 'sent',
        'attemptKey': 'key-u-1',
        'createdAt': '2026-07-10T09:15:00.000Z',
      },
      {
        'id': 'a-1',
        'role': 'assistant',
        'parts': [
          {'type': 'text', 'text': 'Let me check your notes.'},
          {
            'type': 'toolCall',
            'toolCallId': 'call_1',
            'name': 'searchNotes',
            'args': {'period': '2026-06'},
          },
          {
            'type': 'toolResult',
            'toolCallId': 'call_1',
            'content': '3 notes found',
            'isError': false,
          },
          {
            'type': 'providerOpaque',
            'provider': 'openai',
            'data': base64Encode(opaqueBytes),
          },
          {'type': 'text', 'text': 'You noted this plant in June…'},
        ],
        'status': 'complete',
        'attemptKey': 'key-a-1',
        'createdAt': '2026-07-10T09:15:04.000Z',
      },
      {
        'id': 's-1',
        'role': 'system',
        'parts': [
          {'type': 'text', 'text': 'The user renamed the plant.'},
        ],
        'status': 'complete',
        'createdAt': '2026-07-10T09:15:04.000Z',
      },
    ],
  };

  group('exact JSON round-trip (V1_SPEC §5)', () {
    test('toJson produces the exact pinned shape for every part kind', () {
      expect(fullConversation().toJson(), fullConversationJson());
    });

    test('fromJson reads the exact pinned shape back to equal values', () {
      expect(Conversation.fromJson(fullConversationJson()), fullConversation());
    });

    test('survives a real jsonEncode/jsonDecode round-trip', () {
      final encoded = jsonEncode(fullConversation().toJson());
      final decoded = Conversation.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(decoded, fullConversation());
    });
  });

  group('discriminator and enum wire values', () {
    test('part discriminator is "type" with the five pinned values', () {
      expect(const ContentPart.text('t').toJson()['type'], 'text');
      expect(ContentPart.image(imageBytes).toJson()['type'], 'image');
      expect(
        const ContentPart.toolCall('c1', 'n', {}).toJson()['type'],
        'toolCall',
      );
      expect(
        const ContentPart.toolResult('c1', 'ok', true).toJson()['type'],
        'toolResult',
      );
      expect(
        ContentPart.providerOpaque('anthropic', opaqueBytes).toJson()['type'],
        'providerOpaque',
      );
    });

    test('fromJson dispatches on "type" to the right case', () {
      expect(
        ContentPart.fromJson(const {'type': 'text', 'text': 'hello'}),
        isA<TextPart>(),
      );
      expect(
        ContentPart.fromJson({
          'type': 'image',
          'mimeType': 'image/jpeg',
          'data': base64Encode(imageBytes),
        }),
        isA<ImagePart>(),
      );
      expect(
        ContentPart.fromJson(const {
          'type': 'toolCall',
          'toolCallId': 'c1',
          'name': 'n',
          'args': <String, dynamic>{},
        }),
        isA<ToolCallPart>(),
      );
      expect(
        ContentPart.fromJson(const {
          'type': 'toolResult',
          'toolCallId': 'c1',
          'content': 'ok',
          'isError': true,
        }),
        isA<ToolResultPart>(),
      );
      expect(
        ContentPart.fromJson({
          'type': 'providerOpaque',
          'provider': 'openai',
          'data': base64Encode(opaqueBytes),
        }),
        isA<ProviderOpaquePart>(),
      );
    });

    test('role and status enums use the exact wire strings', () {
      Message message(MessageRole role, MessageStatus status) => Message(
        id: 'm',
        role: role,
        parts: const [ContentPart.text('t')],
        status: status,
        attemptKey: 'k',
        createdAt: userCreatedAt,
      );

      expect(
        message(MessageRole.user, MessageStatus.sending).toJson()['role'],
        'user',
      );
      expect(
        message(MessageRole.assistant, MessageStatus.complete).toJson()['role'],
        'assistant',
      );
      expect(
        message(MessageRole.system, MessageStatus.complete).toJson()['role'],
        'system',
      );
      for (final (status, wire) in [
        (MessageStatus.sending, 'sending'),
        (MessageStatus.sent, 'sent'),
        (MessageStatus.failed, 'failed'),
        (MessageStatus.streaming, 'streaming'),
        (MessageStatus.complete, 'complete'),
        (MessageStatus.interrupted, 'interrupted'),
      ]) {
        expect(message(MessageRole.user, status).toJson()['status'], wire);
      }
    });
  });

  group('binary payloads (base64) and the image mimeType', () {
    test('ImagePart always serializes as mimeType image/jpeg + base64', () {
      final json = ContentPart.image(imageBytes).toJson();
      expect(json['mimeType'], 'image/jpeg');
      expect(json['data'], base64Encode(imageBytes));
    });

    test('ImagePart base64 decodes back to the same bytes', () {
      final part = ContentPart.fromJson(ContentPart.image(imageBytes).toJson());
      expect((part as ImagePart).bytes, imageBytes);
    });

    test('a non-JPEG image mimeType is a read error', () {
      expect(
        () => ContentPart.fromJson({
          'type': 'image',
          'mimeType': 'image/png',
          'data': base64Encode(imageBytes),
        }),
        throwsFormatException,
      );
    });

    test('a missing image mimeType is a read error', () {
      expect(
        () => ContentPart.fromJson({
          'type': 'image',
          'data': base64Encode(imageBytes),
        }),
        throwsFormatException,
      );
    });

    test('ProviderOpaquePart.data is base64 and round-trips byte-exact', () {
      final json = ContentPart.providerOpaque('openai', opaqueBytes).toJson();
      expect(json['data'], base64Encode(opaqueBytes));
      final part = ContentPart.fromJson(json);
      expect((part as ProviderOpaquePart).data, opaqueBytes);
    });

    test('an unknown opaque provider is a read error', () {
      expect(
        () => ContentPart.fromJson({
          'type': 'providerOpaque',
          'provider': 'gemini',
          'data': base64Encode(opaqueBytes),
        }),
        throwsFormatException,
      );
    });

    test('malformed base64 is a read error', () {
      expect(
        () => ContentPart.fromJson(const {
          'type': 'image',
          'mimeType': 'image/jpeg',
          'data': 'not base64!!!',
        }),
        throwsFormatException,
      );
    });
  });

  group('createdAt is ISO-8601 UTC', () {
    test('a non-UTC DateTime is written as UTC with the Z suffix', () {
      final local = DateTime.utc(2026, 7, 10, 9, 15).toLocal();
      final json = Message(
        id: 'm',
        role: MessageRole.user,
        parts: const [ContentPart.text('t')],
        status: MessageStatus.sent,
        attemptKey: 'k',
        createdAt: local,
      ).toJson();
      expect(json['createdAt'], '2026-07-10T09:15:00.000Z');
    });

    test('a UTC DateTime is written with the Z suffix', () {
      final json = Message(
        id: 'm',
        role: MessageRole.user,
        parts: const [ContentPart.text('t')],
        status: MessageStatus.sent,
        attemptKey: 'k',
        createdAt: DateTime.utc(2026, 7, 10, 9, 15),
      ).toJson();
      expect(json['createdAt'], '2026-07-10T09:15:00.000Z');
    });

    Message read(String createdAt) => Message.fromJson({
      'id': 'm',
      'role': 'user',
      'parts': const [
        {'type': 'text', 'text': 't'},
      ],
      'status': 'sent',
      'attemptKey': 'k',
      'createdAt': createdAt,
    });

    test('a Z-suffixed timestamp is accepted and stays UTC', () {
      final fromZ = read('2026-07-10T09:15:00Z');
      expect(fromZ.createdAt, DateTime.utc(2026, 7, 10, 9, 15));
      expect(fromZ.createdAt.isUtc, isTrue);
    });

    test('an explicit positive offset normalizes to UTC', () {
      final fromOffset = read('2026-07-10T12:15:00.000+03:00');
      expect(fromOffset.createdAt, DateTime.utc(2026, 7, 10, 9, 15));
      expect(fromOffset.createdAt.isUtc, isTrue);
    });

    test('an explicit negative offset normalizes to UTC', () {
      final fromOffset = read('2026-07-10T04:45:00-04:30');
      expect(fromOffset.createdAt, DateTime.utc(2026, 7, 10, 9, 15));
      expect(fromOffset.createdAt.isUtc, isTrue);
    });

    test(
      'a timezone-naive timestamp is rejected, never read as local time',
      () {
        // DateTime.parse would interpret these in the device's local zone —
        // one JSON must not restore to different instants on different devices.
        for (final naive in [
          '2026-07-10T09:15:00',
          '2026-07-10T09:15:00.000',
          '2026-07-10',
        ]) {
          expect(
            () => read(naive),
            throwsFormatException,
            reason: '"$naive" carries no timezone and must be rejected',
          );
        }
      },
    );

    test('a malformed createdAt string is rejected', () {
      for (final malformed in ['not-a-date', 'nonsenseZ', '']) {
        expect(
          () => read(malformed),
          throwsFormatException,
          reason: '"$malformed" must be rejected',
        );
      }
    });

    test(
      'a naive createdAt is rejected at the Conversation read boundary too',
      () {
        expect(
          () => Conversation.fromJson({
            'schemaVersion': 1,
            'messages': [
              {
                'id': 'm',
                'role': 'user',
                'parts': const [
                  {'type': 'text', 'text': 't'},
                ],
                'status': 'sent',
                'attemptKey': 'k',
                'createdAt': '2026-07-10T09:15:00',
              },
            ],
          }),
          throwsFormatException,
        );
      },
    );
  });

  group('attemptKey null-omission', () {
    test('a null attemptKey is omitted from JSON entirely', () {
      final json = Message(
        id: 's',
        role: MessageRole.system,
        parts: const [ContentPart.text('rule')],
        status: MessageStatus.complete,
        createdAt: userCreatedAt,
      ).toJson();
      expect(json.containsKey('attemptKey'), isFalse);
    });

    test('a non-null attemptKey is written', () {
      final json = Message(
        id: 'u',
        role: MessageRole.user,
        parts: const [ContentPart.text('hi')],
        status: MessageStatus.sent,
        attemptKey: 'key-1',
        createdAt: userCreatedAt,
      ).toJson();
      expect(json['attemptKey'], 'key-1');
    });
  });

  group('read policy: unknown fields are ignored', () {
    test('extra fields at every level are accepted', () {
      // Re-decode so every nested map is Map<String, dynamic> and mutable.
      final json =
          jsonDecode(jsonEncode(fullConversationJson()))
              as Map<String, dynamic>;
      json['appMeta'] = {'pinned': true};
      final message =
          (json['messages'] as List<dynamic>).first as Map<String, dynamic>;
      message['clientTag'] = 'row-42';
      final part =
          (message['parts'] as List<dynamic>).first as Map<String, dynamic>;
      part['weird'] = 1;

      expect(Conversation.fromJson(json), fullConversation());
    });
  });

  group('read policy: unknown values are rejected', () {
    Map<String, dynamic> conversationWith({
      Object? schemaVersion = 1,
      String role = 'user',
      String status = 'sent',
      String partType = 'text',
    }) => {
      'schemaVersion': ?schemaVersion,
      'messages': [
        {
          'id': 'm-1',
          'role': role,
          'parts': [
            {'type': partType, 'text': 't'},
          ],
          'status': status,
          'attemptKey': 'k',
          'createdAt': '2026-07-10T09:15:00Z',
        },
      ],
    };

    test('schemaVersion other than integer 1 is rejected', () {
      for (final version in [0, 2, '1', null]) {
        expect(
          () => Conversation.fromJson(conversationWith(schemaVersion: version)),
          throwsFormatException,
          reason: 'schemaVersion $version must be rejected',
        );
      }
    });

    test('an unknown part type is rejected', () {
      expect(
        () => Conversation.fromJson(conversationWith(partType: 'file')),
        throwsFormatException,
      );
    });

    test('an unknown role is rejected', () {
      expect(
        () => Conversation.fromJson(conversationWith(role: 'tool')),
        throwsFormatException,
      );
    });

    test('an unknown status is rejected', () {
      expect(
        () => Conversation.fromJson(conversationWith(status: 'queued')),
        throwsFormatException,
      );
    });

    test('a structurally malformed document is rejected, not crashed on', () {
      expect(
        () => Conversation.fromJson(const {'schemaVersion': 1}),
        throwsFormatException,
      );
      expect(
        () => Conversation.fromJson(const {
          'schemaVersion': 1,
          'messages': [1, 2],
        }),
        throwsFormatException,
      );
    });
  });
}
