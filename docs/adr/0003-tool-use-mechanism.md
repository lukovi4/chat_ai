---
status: accepted
---

# Tool use (function calling) is a v1 mechanism; tools are the app's, executed by the app

Apps will give their chats capabilities — search a local DB, create a mood card,
write a product, fill a table — but **no concrete tools exist yet** and their shapes
aren't known. So v1 ships the **mechanism** (the socket), not any tool (the plug):
the Core declares Tools to the bot, recognises a tool-call as a state
(`AwaitingTool`), hands it to the app, takes the result back, and continues the
loop. The Package **never implements or executes a Tool** — that is app code
touching the app's DB. The Message model carries ordered `tool-call` /
`tool-result` parts inside the assistant Message from day one, so the first real
tool drops in without changing the Package.

## Considered Options

- **Defer tool use entirely to v2.** Rejected: the user's apps need chat
  capabilities, and retrofitting tool-use would force breaking changes to the
  Message model and Conversation State. Laying the form now is the whole point.
- **Bake specific tools into the Package.** Rejected: no tools are known yet, and
  tool execution is app/business logic (its DB) — never the Package's. The Package
  is a socket, not a plug.
- **Normalise tool formats on the client.** Rejected for the same reason as SSE
  normalisation (ADR 0001): it would make the Core provider-aware. Normalisation —
  and the buffering/validation of streamed argument JSON — happens on the **server**.

## Consequences

- Assistant Message gains `tool-call` / `tool-result` Content Parts;
  Conversation State gains `AwaitingTool`.
- Tool declarations use the portable **Chat AI Tool Schema v1** dialect; the proxy translates to
  each provider and **assembles/validates streamed argument JSON server-side**,
  emitting a complete `tool_call` event (SERVER-CONTRACT.md §7). The Core never
  parses partial tool JSON.
- An interrupted tool-call applies nothing and surfaces `upstream` (Retry Boundary).
- The tool-result round-trip reuses the Idempotency-Key discipline — with its
  own fresh key per leg (ADR 0004 / SERVER-CONTRACT.md §6–§7).
- **v1 mandates the proxy disable parallel tool-calls** (both providers ship
  the switch — `parallel_tool_calls: false` / `disable_parallel_tool_use:
  true`; SERVER-CONTRACT.md §7): at most one `tool_call` per leg, so the
  single-call `AwaitingTool` cannot desynchronise from the bot. Parallel/
  multiple tool-calls and richer tool features are v2 and extend this without
  re-architecting (the loop and the event already exist).

## Amendment (2026-07-10, pre-implementation review)

The final pre-implementation model is:

- **There is no `tool` role in v1.** The tool-result lives as a `toolResult`
  Content Part **inside the same assistant Message**, ordered after its
  `toolCall` part — one reply = one assistant Message whose parts follow
  `text* (toolCall toolResult text*)* toolCall?`. Rationale: a separate
  tool-role message either breaks "one assistant message stays `streaming`
  across a multi-leg reply" or breaks part ordering in a flat message list;
  embedding preserves both, and Context Trimming (whole Messages) can never
  separate a call from its result. The proxy splits the parts into provider
  shapes on the wire. A dead public enum value would be worse than adding the
  role back later (additive, breaks only strict consumers).
- **Tool execution semantics are honestly at-least-once.** After a
  restart/recovery the app may see the same call again with the same
  `toolCallId`; side-effecting Tools MUST deduplicate by `toolCallId`. The
  Core's own guarantee: the resolver is never invoked for a call whose
  matching result already exists, and cancel never rolls back an already-run
  Tool. Exactly-once is not promised (and not buildable from the Package's
  side).

## Amendment (2026-07-10, implementation hardening)

- OpenAI reasoning items and Anthropic thinking/redacted-thinking blocks are
  preserved as ordered hidden `ProviderOpaquePart`s through the same app-owned
  assistant Message. They are never rendered or exposed to `partBuilder`, and
  are sent back only to the provider that produced them. This is continuity for
  the existing stateless tool loop, not a new product content type.
- Provider adapters buffer streamed argument fragments and validate the complete
  call against the frozen Tool declaration/schema. The Core repeats the trust
  check: unknown tool or invalid arguments never invoke the resolver and become
  a safe `is_error` result. Resolver exceptions are sanitised before becoming an
  `is_error` result.
- Declarations use the closed portable Chat AI Tool Schema v1 dialect from
  SERVER-CONTRACT §7, with one shared Dart/TypeScript/provider fixture corpus;
  provider-specific schema extensions are rejected rather than interpreted
  differently.
