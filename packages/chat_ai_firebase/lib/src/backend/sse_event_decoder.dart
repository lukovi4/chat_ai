import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';

import 'sse_parser.dart';

/// Internal decoder of ONE framed, normalized SSE event (V1_SPEC §6
/// "Response — the SSE stream", SERVER-CONTRACT §2) into its [BackendEvent].
/// Not exported from `package:chat_ai/chat_ai.dart`.
///
/// Exactly one frame in, exactly one event out — nothing more:
/// - it does not read byte streams and does not order/track events;
/// - it does not track terminals: first-terminal-wins, duplicate-terminal
///   and event-after-terminal policies (V1_SPEC §8) belong to the future
///   stream-lifecycle layer, which also converts this decoder's
///   [FormatException]s (and the framer's strict-UTF-8 ones) into exactly
///   one `ErrorEvent(upstream)` so no exception escapes the public
///   `ChatBackend.send` stream;
/// - it never produces [Accepted], [ConflictEvent] or [GoneEvent]: those are
///   HTTP-layer facts (wire-version check, HTTP 409/410, pre-stream
///   failures — V1_SPEC §6 "Protocol signals"), not SSE events.
///
/// Wire rules enforced here (violations throw [FormatException]):
/// - the event name must be one of `delta | provider_state | tool_call |
///   done | error`; a null/empty/unknown name is a wire defect;
/// - the data payload must be a JSON object with the pinned fields; missing
///   required fields and wrong types (required or optional) are defects;
/// - `provider_state.provider` is `openai` or `anthropic`; `data` is base64
///   and decodes byte-exact;
/// - `error.cause` is one of the nine kebab-case wire codes; the catalogue's
///   tenth code `tool-loop-limit` is client-only and never crosses the wire
///   (SERVER-CONTRACT §2), so it is rejected too;
/// - `Usage` decodes from `{inputTokens: int, outputTokens: int,
///   usageRaw?: object}`; unknown JSON fields are ignored everywhere.
///
/// Every [FormatException] thrown here is **sanitized**: no `source`, no
/// offset, no wire payload in the message. SSE data may hold user text, tool
/// args or provider opaque state — none of it may reach future logs-only
/// diagnostics through an exception. Messages are short and stable; the only
/// dynamic parts are the five known event names.
BackendEvent decodeSseFrame(SseFrame frame) {
  final event = frame.event;
  switch (event) {
    case 'delta':
      final json = _dataObject(frame.data, 'delta');
      return BackendEvent.delta(_field<String>(json, 'text', 'delta'));
    case 'provider_state':
      final json = _dataObject(frame.data, 'provider_state');
      final provider = _field<String>(json, 'provider', 'provider_state');
      if (provider != 'openai' && provider != 'anthropic') {
        // Sanitized: the received value is wire payload and is not echoed.
        throw const FormatException(
          "SSE 'provider_state' event: unknown provider",
        );
      }
      final encoded = _field<String>(json, 'data', 'provider_state');
      final Uint8List bytes;
      try {
        bytes = base64Decode(encoded);
      } on FormatException {
        // Sanitized: the native FormatException carries the raw string in
        // `source`; opaque provider state must not leak through it.
        throw const FormatException(
          "SSE 'provider_state' event: malformed base64 data",
        );
      }
      return BackendEvent.providerState(ProviderOpaquePart(provider, bytes));
    case 'tool_call':
      final json = _dataObject(frame.data, 'tool_call');
      return BackendEvent.toolCall(
        ToolCall(
          id: _field<String>(json, 'id', 'tool_call'),
          name: _field<String>(json, 'name', 'tool_call'),
          args: _field<Map<String, dynamic>>(json, 'args', 'tool_call'),
        ),
        usage: _usage(json, 'tool_call'),
      );
    case 'done':
      final json = _dataObject(frame.data, 'done');
      return BackendEvent.done(usage: _usage(json, 'done'));
    case 'error':
      final json = _dataObject(frame.data, 'error');
      final retryAfterMs = _optionalField<int>(json, 'retryAfterMs', 'error');
      return BackendEvent.error(
        _cause(_field<String>(json, 'cause', 'error')),
        detail: _optionalField<String>(json, 'detail', 'error'),
        usage: _usage(json, 'error'),
        retryAfter: retryAfterMs == null
            ? null
            : Duration(milliseconds: retryAfterMs),
      );
    default:
      // Sanitized: an unknown event name is wire payload and is not echoed.
      throw const FormatException('Unknown or missing SSE event');
  }
}

/// The nine kebab-case wire cause codes (V1_SPEC §6, SERVER-CONTRACT §2).
/// `tool-loop-limit` is deliberately absent: client-only, never on the wire.
const Map<String, FailureCause> _wireCauses = {
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

FailureCause _cause(String wire) {
  final cause = _wireCauses[wire];
  if (cause == null) {
    // Sanitized: the received value is wire payload and is not echoed. The
    // "tool-loop-limit" literal below is the matched constant, not payload.
    throw FormatException(
      wire == 'tool-loop-limit'
          ? "SSE 'error' event: cause \"tool-loop-limit\" is client-only and "
                'never crosses the wire'
          : "SSE 'error' event: unknown cause",
    );
  }
  return cause;
}

/// Parses the frame data as a JSON object. Malformed JSON is re-thrown as a
/// sanitized [FormatException]: the native one from [jsonDecode] carries the
/// whole wire payload in `source`/`toString()`. The `event` name here is
/// always one of the five known constants, never wire payload.
Map<String, dynamic> _dataObject(String data, String event) {
  final Object? root;
  try {
    root = jsonDecode(data);
  } on FormatException {
    throw FormatException("SSE '$event' event: malformed JSON");
  }
  if (root is! Map<String, dynamic>) {
    throw FormatException(
      "SSE '$event' event: data must be a JSON object, "
      'got: ${root.runtimeType}',
    );
  }
  return root;
}

/// A required field: missing or wrongly typed → [FormatException].
T _field<T extends Object>(
  Map<String, dynamic> json,
  String field,
  String event,
) {
  final Object? value = json[field];
  if (value is! T) {
    throw FormatException(
      "SSE '$event' event: required field '$field' must be $T, "
      'got: ${value.runtimeType}',
    );
  }
  return value;
}

/// An optional field: absent/null → null; present with a wrong type →
/// [FormatException].
T? _optionalField<T extends Object>(
  Map<String, dynamic> json,
  String field,
  String event,
) {
  final Object? value = json[field];
  if (value == null) {
    return null;
  }
  if (value is! T) {
    throw FormatException(
      "SSE '$event' event: optional field '$field' must be $T, "
      'got: ${value.runtimeType}',
    );
  }
  return value;
}

/// The optional `usage` object (V1_SPEC §6): `inputTokens`/`outputTokens`
/// are required ints, `usageRaw` is an optional object; unknown fields are
/// ignored; no further value constraints.
Usage? _usage(Map<String, dynamic> json, String event) {
  final usage = _optionalField<Map<String, dynamic>>(json, 'usage', event);
  if (usage == null) {
    return null;
  }
  return Usage(
    inputTokens: _field<int>(usage, 'inputTokens', event),
    outputTokens: _field<int>(usage, 'outputTokens', event),
    usageRaw: _optionalField<Map<String, dynamic>>(usage, 'usageRaw', event),
  );
}
