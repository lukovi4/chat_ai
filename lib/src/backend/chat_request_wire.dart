import 'dart:convert';

import 'chat_request.dart';

/// Internal canonical serializer of one [ChatRequest] into its exact JSON
/// body form (V1_SPEC §6). In the core it exists for exactly one caller: the
/// `ChatSession` payload-size probe, which measures the byte length of the
/// would-be request against the pre-backend 10 MB gate (V1_SPEC §11/§12).
/// It is NOT a transport implementation and is not exported from
/// `package:chat_ai/chat_ai.dart`. The Firebase adapter (`chat_ai_firebase`)
/// carries its own package-local copy of this function for the actual wire
/// request; both copies are pinned by identical frozen contract tests.
///
/// Returns a compact JSON **string**, not a map. Two calls over the same
/// unchanged request yield the identical string; no canonicalizer and no
/// key sorting are involved.
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
/// - `idempotencyKey` is NEVER in the body: the adapter's HTTP layer sends it
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
