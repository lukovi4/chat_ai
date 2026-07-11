---
status: accepted
---

# Stateless context assembly on the client; history stored by the app

The Package is **stateless**: the Core assembles each bot request on the client —
`[system prompt from Bot Profile] + [prior Messages] + [new Message]` — and neither
the Core nor the proxy keeps durable history server-side. Conversation history is owned and
stored by the **Consuming App** (any DB it likes), handed to the Core as data on
open and saved back from the Core's serializable snapshot after each reply.

## Considered Options

- **Server-side conversation state** (OpenAI `previous_response_id` /
  Conversations API; a package-server DB). Rejected for two reasons that compound:
  (1) it would put history in a server/DB, but the package server is reserved
  for the **critical-only** (the provider key, ADR 0001), and storage is
  explicitly the app's job — a second copy of every chat would appear
  server-side with no owner and no benefit; (2) **money is neutral either
  way** — the providers' prompt caching discounts a repeated prefix by its
  bytes, not by who stores it, so a client-resent history caches exactly as
  well as a server-stored one; server-side state buys a few KB of upload, not
  generation cost. *(An earlier revision of this ADR claimed "server-side
  history does not save money because every prior token is re-billed
  regardless" — that overstated the case by ignoring prompt caching; the
  decision stands on the two reasons above.)*

## Consequences

- No database in the Package, and none required merely to chat. A DB is needed only
  to persist chats across launches — and that DB is the **app's**.
- The system prompt / bot persona lives in the **Bot Profile on the app side**; the
  Core only carries it as a parameter. A consequence: a determined user could in
  principle inspect/alter the client-sent prompt — acceptable for the personal,
  small-audience profile; hiding the prompt server-side is a later option, not v1.
- Long conversations grow the per-turn token cost and approach the context window;
  trimming is therefore a real concern (see Context Trimming) and
  `context-too-long` is an enumerated Failure.

## Amendment (2026-07-10, implementation hardening)

- An app that persists chats across launches supplies an awaited Conversation
  checkpoint. The Core persists the Message and `attemptKey` through that
  callback before every new billable provider dispatch. `checkpoint: null` is
  valid only for an app that intentionally has no cross-launch chat storage.
- "Stateless" means **no durable server-side conversation history**. A terminal
  normalised outcome is temporarily held for the short idempotency replay TTL
  (ADR 0006); it is recovery state, not a second chat database.
- Some provider APIs require opaque reasoning/thinking continuity across tool
  legs. The Core stores those bytes as a hidden provider-opaque part in the
  app-owned Conversation and returns them only to the matching provider. The
  Package does not interpret or render them; provider-managed conversation state
  remains disabled (`store:false`, no response/thread chaining).
