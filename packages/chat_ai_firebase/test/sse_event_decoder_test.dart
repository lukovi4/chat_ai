// The internal one-frame SSE event decoder (V1_SPEC §6, SERVER-CONTRACT §2):
// SseFrame → BackendEvent, with FormatException on every wire-form defect.
// Imports internal files directly — neither type is exported from
// package:chat_ai/chat_ai.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_firebase/src/backend/sse_event_decoder.dart';
import 'package:chat_ai_firebase/src/backend/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

BackendEvent decode(String? event, String data) =>
    decodeSseFrame(SseFrame(event: event, data: data));

void main() {
  group('delta', () {
    test('decodes {"text": …} into BackendEvent.delta', () {
      expect(
        decode('delta', '{"text":"Hel"}'),
        const BackendEvent.delta('Hel'),
      );
    });

    test('an empty text chunk is legal', () {
      expect(decode('delta', '{"text":""}'), const BackendEvent.delta(''));
    });
  });

  group('provider_state', () {
    test('decodes both providers with byte-exact base64 data', () {
      final bytes = Uint8List.fromList([0, 1, 255, 128, 7]);
      for (final provider in ['openai', 'anthropic']) {
        expect(
          decode(
            'provider_state',
            '{"provider":"$provider","data":"${base64Encode(bytes)}"}',
          ),
          BackendEvent.providerState(ProviderOpaquePart(provider, bytes)),
          reason: 'provider $provider must round-trip byte-exact',
        );
      }
    });

    test('an unknown provider is a wire defect', () {
      expect(
        () => decode('provider_state', '{"provider":"gemini","data":"AQID"}'),
        throwsFormatException,
      );
    });

    test('malformed base64 data is a wire defect', () {
      expect(
        () => decode(
          'provider_state',
          '{"provider":"openai","data":"not base64!!!"}',
        ),
        throwsFormatException,
      );
    });
  });

  group('tool_call', () {
    test('decodes id/name/args without usage', () {
      expect(
        decode(
          'tool_call',
          '{"id":"call_1","name":"searchNotes","args":{"period":"2026-06"}}',
        ),
        const BackendEvent.toolCall(
          ToolCall(
            id: 'call_1',
            name: 'searchNotes',
            args: {'period': '2026-06'},
          ),
        ),
      );
    });

    test('decodes the optional leg usage', () {
      expect(
        decode(
          'tool_call',
          '{"id":"call_1","name":"searchNotes","args":{},'
              '"usage":{"inputTokens":123,"outputTokens":45}}',
        ),
        const BackendEvent.toolCall(
          ToolCall(id: 'call_1', name: 'searchNotes', args: {}),
          usage: Usage(inputTokens: 123, outputTokens: 45),
        ),
      );
    });
  });

  group('done', () {
    test('decodes without usage (empty object and JSON null)', () {
      expect(decode('done', '{}'), const BackendEvent.done());
      expect(decode('done', '{"usage":null}'), const BackendEvent.done());
    });

    test('decodes usage with usageRaw', () {
      expect(
        decode(
          'done',
          '{"usage":{"inputTokens":123,"outputTokens":456,'
              '"usageRaw":{"total_tokens":579}}}',
        ),
        const BackendEvent.done(
          usage: Usage(
            inputTokens: 123,
            outputTokens: 456,
            usageRaw: {'total_tokens': 579},
          ),
        ),
      );
    });
  });

  group('error', () {
    test('decodes all nine wire cause codes', () {
      const wire = {
        'auth': FailureCause.auth,
        'entitlement': FailureCause.entitlement,
        'quota': FailureCause.quota,
        'rate': FailureCause.rate,
        'overloaded': FailureCause.overloaded,
        'content-filter': FailureCause.contentFilter,
        'context-too-long': FailureCause.contextTooLong,
        'network': FailureCause.network,
        'upstream': FailureCause.upstream,
      };
      for (final MapEntry(key: code, value: cause) in wire.entries) {
        expect(
          decode('error', '{"cause":"$code"}'),
          BackendEvent.error(cause),
          reason: 'wire code "$code" must map to $cause',
        );
      }
    });

    test('decodes all optional fields incl. retryAfterMs → Duration', () {
      expect(
        decode(
          'error',
          '{"cause":"rate","detail":"429 from provider",'
              '"usage":{"inputTokens":10,"outputTokens":2},"retryAfterMs":1200}',
        ),
        const BackendEvent.error(
          FailureCause.rate,
          detail: '429 from provider',
          usage: Usage(inputTokens: 10, outputTokens: 2),
          retryAfter: Duration(milliseconds: 1200),
        ),
      );
    });

    test('the client-only tool-loop-limit cause is rejected on the wire', () {
      expect(
        () => decode('error', '{"cause":"tool-loop-limit"}'),
        throwsFormatException,
      );
    });

    test('unknown and non-kebab-case causes are rejected', () {
      for (final code in ['billing', 'contentFilter', 'contextTooLong', '']) {
        expect(
          () => decode('error', '{"cause":"$code"}'),
          throwsFormatException,
          reason: 'cause "$code" must be rejected',
        );
      }
    });
  });

  group('read policy: unknown JSON fields are ignored', () {
    test('extra fields at event and usage level do not affect decoding', () {
      expect(
        decode('delta', '{"text":"x","weird":1,"streamId":"s1"}'),
        const BackendEvent.delta('x'),
      );
      expect(
        decode(
          'done',
          '{"usage":{"inputTokens":1,"outputTokens":2,"cost":0.01},"eventId":7}',
        ),
        const BackendEvent.done(usage: Usage(inputTokens: 1, outputTokens: 2)),
      );
    });
  });

  group('sanitized exceptions (no wire payload leakage)', () {
    test('FormatException carries no source and never echoes the payload', () {
      const sentinel = 'LEAK_SENTINEL_9f27c';
      // (label, event, data) — every failure path whose input embeds the
      // sentinel somewhere in the wire payload:
      const cases = [
        ('malformed JSON', 'delta', '{"text":"$sentinel'),
        (
          'malformed base64',
          'provider_state',
          '{"provider":"openai","data":"$sentinel!!!"}',
        ),
        ('unknown event', '$sentinel-event', '{}'),
        (
          'unknown provider',
          'provider_state',
          '{"provider":"$sentinel","data":"AQID"}',
        ),
        ('unknown cause', 'error', '{"cause":"$sentinel"}'),
      ];
      for (final (label, event, data) in cases) {
        FormatException? caught;
        try {
          decode(event, data);
        } on FormatException catch (exception) {
          caught = exception;
        }
        expect(caught, isNotNull, reason: '$label must throw FormatException');
        expect(
          caught!.source,
          isNull,
          reason: '$label: exception.source must be null',
        );
        expect(
          caught.toString().contains(sentinel),
          isFalse,
          reason: '$label: toString() must not leak the wire payload',
        );
      }
    });
  });

  group('wire-form defects → FormatException', () {
    test('a null, empty or unknown event name is rejected', () {
      for (final event in [null, '', 'deltas', 'ping', 'message']) {
        expect(
          () => decode(event, '{"text":"x"}'),
          throwsFormatException,
          reason: 'event "$event" must be rejected',
        );
      }
    });

    test('accepted/conflict/gone are not SSE events and are rejected', () {
      // Accepted is asserted by the HTTP layer; 409/410 are HTTP statuses
      // (V1_SPEC §6 "Protocol signals") — never event names on the wire.
      for (final event in ['accepted', 'conflict', 'gone']) {
        expect(
          () => decode(event, '{}'),
          throwsFormatException,
          reason: 'event "$event" must be rejected',
        );
      }
    });

    test('malformed JSON data is rejected', () {
      for (final event in [
        'delta',
        'provider_state',
        'tool_call',
        'done',
        'error',
      ]) {
        expect(
          () => decode(event, '{oops'),
          throwsFormatException,
          reason: 'malformed JSON on "$event" must be rejected',
        );
      }
    });

    test('a non-object JSON root is rejected', () {
      for (final data in ['"str"', '[1,2]', '42', 'null', 'true']) {
        expect(
          () => decode('done', data),
          throwsFormatException,
          reason: 'root $data must be rejected',
        );
      }
    });

    test('missing required fields are rejected', () {
      const cases = [
        ('delta', '{}'),
        ('provider_state', '{"data":"AQID"}'), // no provider
        ('provider_state', '{"provider":"openai"}'), // no data
        ('tool_call', '{"name":"n","args":{}}'), // no id
        ('tool_call', '{"id":"c1","args":{}}'), // no name
        ('tool_call', '{"id":"c1","name":"n"}'), // no args
        ('error', '{"detail":"x"}'), // no cause
      ];
      for (final (event, data) in cases) {
        expect(
          () => decode(event, data),
          throwsFormatException,
          reason: '"$event" with $data must be rejected',
        );
      }
    });

    test('wrongly typed required and optional fields are rejected', () {
      const cases = [
        ('delta', '{"text":5}'),
        ('provider_state', '{"provider":7,"data":"AQID"}'),
        ('provider_state', '{"provider":"openai","data":9}'),
        ('tool_call', '{"id":1,"name":"n","args":{}}'),
        ('tool_call', '{"id":"c1","name":[],"args":{}}'),
        ('tool_call', '{"id":"c1","name":"n","args":[1]}'),
        ('done', '{"usage":5}'),
        ('done', '{"usage":{"inputTokens":"1","outputTokens":2}}'),
        ('done', '{"usage":{"inputTokens":1,"outputTokens":2.5}}'),
        ('done', '{"usage":{"inputTokens":1}}'), // outputTokens missing
        ('done', '{"usage":{"inputTokens":1,"outputTokens":2,"usageRaw":"x"}}'),
        ('error', '{"cause":5}'),
        ('error', '{"cause":"rate","detail":7}'),
        ('error', '{"cause":"rate","retryAfterMs":"1200"}'),
        ('error', '{"cause":"rate","retryAfterMs":1.2}'),
      ];
      for (final (event, data) in cases) {
        expect(
          () => decode(event, data),
          throwsFormatException,
          reason: '"$event" with $data must be rejected',
        );
      }
    });
  });
}
