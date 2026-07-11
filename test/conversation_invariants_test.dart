// Every Conversation/Message invariant of V1_SPEC §5, checked one by one
// through the public read boundary `Conversation.fromJson`.
import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

const _text = {'type': 'text', 'text': 't'};
const _image = {'type': 'image', 'mimeType': 'image/jpeg', 'data': 'AQID'};
const _opaque = {
  'type': 'providerOpaque',
  'provider': 'openai',
  'data': 'AQID',
};

Map<String, dynamic> _call(String id) => {
  'type': 'toolCall',
  'toolCallId': id,
  'name': 'searchNotes',
  'args': <String, dynamic>{},
};

Map<String, dynamic> _result(String id) => {
  'type': 'toolResult',
  'toolCallId': id,
  'content': 'ok',
  'isError': false,
};

Map<String, dynamic> _message({
  String id = 'm-1',
  String role = 'user',
  String status = 'sent',
  List<Map<String, dynamic>> parts = const [_text],
  String? attemptKey = 'k-1',
}) => {
  'id': id,
  'role': role,
  'parts': parts,
  'status': status,
  'attemptKey': ?attemptKey,
  'createdAt': '2026-07-10T09:15:00Z',
};

Map<String, dynamic> _conversation(List<Map<String, dynamic>> messages) => {
  'schemaVersion': 1,
  'messages': messages,
};

void _expectRejected(
  List<Map<String, dynamic>> messages, {
  required String reason,
}) {
  expect(
    () => Conversation.fromJson(_conversation(messages)),
    throwsFormatException,
    reason: reason,
  );
}

void main() {
  group('Message.id uniqueness', () {
    test('duplicate ids in one Conversation are rejected', () {
      _expectRejected([
        _message(id: 'dup'),
        _message(id: 'dup'),
      ], reason: 'two Messages share id "dup"');
    });

    test('distinct ids pass', () {
      final conversation = Conversation.fromJson(
        _conversation([_message(id: 'a'), _message(id: 'b')]),
      );
      expect(conversation.messages, hasLength(2));
    });
  });

  group('role ↔ status', () {
    test('user accepts sending|sent|failed only', () {
      for (final status in ['sending', 'sent', 'failed']) {
        expect(
          Conversation.fromJson(_conversation([_message(status: status)])),
          isA<Conversation>(),
          reason: 'user + $status is legal',
        );
      }
      for (final status in ['streaming', 'complete', 'interrupted']) {
        _expectRejected([
          _message(status: status),
        ], reason: 'user + $status must be rejected');
      }
    });

    test('assistant accepts streaming|complete|interrupted only', () {
      for (final status in ['streaming', 'complete', 'interrupted']) {
        expect(
          Conversation.fromJson(
            _conversation([_message(role: 'assistant', status: status)]),
          ),
          isA<Conversation>(),
          reason: 'assistant + $status is legal',
        );
      }
      for (final status in ['sending', 'sent', 'failed']) {
        _expectRejected([
          _message(role: 'assistant', status: status),
        ], reason: 'assistant + $status must be rejected');
      }
    });

    test('system is always complete', () {
      expect(
        Conversation.fromJson(
          _conversation([
            _message(role: 'system', status: 'complete', attemptKey: null),
          ]),
        ),
        isA<Conversation>(),
      );
      for (final status in [
        'sending',
        'sent',
        'failed',
        'streaming',
        'interrupted',
      ]) {
        _expectRejected([
          _message(role: 'system', status: status, attemptKey: null),
        ], reason: 'system + $status must be rejected');
      }
    });
  });

  group('attemptKey required / forbidden', () {
    test('a user Message without attemptKey is rejected', () {
      _expectRejected([
        _message(attemptKey: null),
      ], reason: 'user Messages require the persisted send key');
    });

    test('an assistant Message without attemptKey is rejected', () {
      _expectRejected([
        _message(role: 'assistant', status: 'complete', attemptKey: null),
      ], reason: 'assistant Messages require the current/last leg key');
    });

    test('a system Message with attemptKey is rejected', () {
      _expectRejected([
        _message(role: 'system', status: 'complete', attemptKey: 'k'),
      ], reason: 'system Messages never carry an attemptKey');
    });
  });

  group('system Messages are text-only', () {
    for (final (label, part) in [
      ('image', _image),
      ('toolCall', _call('c1')),
      ('toolResult', _result('c1')),
      ('providerOpaque', _opaque),
    ]) {
      test('a system Message with a $label part is rejected', () {
        _expectRejected([
          _message(
            role: 'system',
            status: 'complete',
            attemptKey: null,
            parts: [_text, part],
          ),
        ], reason: 'system Messages are text-only');
      });
    }
  });

  group('tool/opaque parts never on user Messages', () {
    for (final (label, part) in [
      ('toolCall', _call('c1')),
      ('toolResult', _result('c1')),
      ('providerOpaque', _opaque),
    ]) {
      test('a user Message with a $label part is rejected', () {
        _expectRejected([
          _message(parts: [_text, part]),
        ], reason: 'tool and provider-opaque parts are assistant-only');
      });
    }

    test('an image-only user Message is legal (image with no text)', () {
      expect(
        Conversation.fromJson(
          _conversation([
            _message(parts: [_image]),
          ]),
        ),
        isA<Conversation>(),
      );
    });
  });

  group(
    'assistant visible grammar: text* (toolCall toolResult text*)* toolCall?',
    () {
      Map<String, dynamic> assistant(
        List<Map<String, dynamic>> parts, {
        String status = 'complete',
      }) => _message(role: 'assistant', status: status, parts: parts);

      test('a toolResult without a preceding toolCall is rejected', () {
        _expectRejected([
          assistant([_result('c1')]),
        ], reason: 'result before any call');
      });

      test('text between a toolCall and its toolResult is rejected', () {
        _expectRejected([
          assistant([_call('c1'), _text, _result('c1')]),
        ], reason: 'an open call must be resolved before more text');
      });

      test('a second toolCall before the first resolves is rejected', () {
        _expectRejected([
          assistant([_call('c1'), _call('c2'), _result('c1'), _result('c2')]),
        ], reason: 'no parallel tool calls in v1');
      });

      test('a toolResult not matching the open call is rejected', () {
        _expectRejected([
          assistant([_call('c1'), _result('other')]),
        ], reason: 'a result pairs with the nearest unclosed call');
      });

      test('a duplicate toolCallId inside one reply is rejected', () {
        _expectRejected([
          assistant([_call('c1'), _result('c1'), _call('c1'), _result('c1')]),
        ], reason: 'toolCallId is unique inside one logical reply');
      });

      test('a trailing unmatched toolCall on complete is rejected', () {
        _expectRejected([
          assistant([_text, _call('c1')]),
        ], reason: 'a complete Message never has an unmatched call');
      });

      test(
        'a trailing unmatched toolCall on streaming/interrupted is legal',
        () {
          for (final status in ['streaming', 'interrupted']) {
            expect(
              Conversation.fromJson(
                _conversation([
                  assistant([_text, _call('c1')], status: status),
                ]),
              ),
              isA<Conversation>(),
              reason: 'an in-flight/interrupted reply may hold the open call',
            );
          }
        },
      );

      test('an image part on an assistant Message is rejected', () {
        _expectRejected([
          assistant([_text, _image]),
        ], reason: 'assistant content is text/tool/opaque only');
      });

      test('provider-opaque parts are ignored by the grammar', () {
        final conversation = Conversation.fromJson(
          _conversation([
            assistant([
              _text,
              _call('c1'),
              _opaque, // between the call and its result — still legal
              _result('c1'),
              _opaque,
              _text,
            ]),
          ]),
        );
        expect(conversation.messages.single.parts, hasLength(6));
      });

      test('a full multi-exchange reply passes', () {
        expect(
          Conversation.fromJson(
            _conversation([
              assistant([
                _text,
                _call('c1'),
                _result('c1'),
                _text,
                _call('c2'),
                _result('c2'),
                _text,
              ]),
            ]),
          ),
          isA<Conversation>(),
        );
      });

      test(
        'an empty complete assistant Message is legal (stays in storage)',
        () {
          expect(
            Conversation.fromJson(_conversation([assistant(const [])])),
            isA<Conversation>(),
          );
        },
      );
    },
  );
}
