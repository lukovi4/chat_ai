import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';

/// Internal wire-encoder of one [ChatRequest] into the exact JSON body of
/// the POST request (V1_SPEC §6 "Request (client → proxy)";
/// SERVER-CONTRACT §5). Not exported from `package:chat_ai/chat_ai.dart`.
///
/// Returns a compact JSON **string**, not a map: the Core freezes the
/// serialized request for the lifetime of an Attempt and every silent retry
/// re-sends it byte-identical (V1_SPEC §8) — the future Core stores this
/// function's result once. Two calls over the same unchanged request yield
/// the identical string; no canonicalizer and no key sorting are involved
/// (the server does its own canonical provider-effective normalisation,
/// SERVER-CONTRACT §6).
///
/// The exact body shape:
/// - `wireVersion`, `botId`, `system` and `messages` are always present;
/// - `messages` reuse the **storage JSON of `Message`** (V1_SPEC §5/§6: one
///   serializer, no second mapper) — client-only fields (`id`, `status`,
///   `createdAt`, `attemptKey`) ride along and the proxy ignores them;
/// - `tools` is omitted entirely when [ChatRequest.tools] is empty;
///   otherwise each Tool encodes exactly as `{name, description,
///   parameters}`, with the `parameters` JSON Schema passed through as-is —
///   unknown fields included, no schema validation here;
/// - `idempotencyKey` is NEVER in the body: the future HTTP layer sends it
///   only as the `Idempotency-Key` header (ADR 0004).
///
/// Out of scope by contract: history filtering / context assembly (the Core
/// hands in an already-assembled request), provider mapping, `paramsHash`,
/// wireVersion/UUID validation, and any network I/O.
String encodeChatRequestBody(ChatRequest request) => jsonEncode({
  'wireVersion': request.wireVersion,
  'botId': request.botId,
  'system': request.system,
  'messages': [for (final message in request.messages) message.toJson()],
  if (request.tools.isNotEmpty)
    'tools': [
      for (final tool in request.tools)
        {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
    ],
});
