---
status: accepted
---

# Idempotency-Key is a client-minted UUID per attempt, not a content hash

The `Idempotency-Key` the client sends with each billable request is a random
V4 UUID minted per **new Attempt**. Send, edit-rerun, regenerate of a complete
reply, and each new tool leg mint a fresh key. Everything that requests the
outcome of an existing Attempt — silent pre-first-token retries, explicit
resend of a `failed` user Message, and recovery-first regenerate of an
`interrupted` reply — carries the persisted key. This supersedes the original
content-derived design ("a hash of the
assembled context + Bot Profile + conversation id") in earlier revisions of
CONTEXT.md / SERVER-CONTRACT.md §6 (the latter now ships with the Firebase
adapter: `packages/chat_ai_firebase/docs/`).

This is the industry pattern: Stripe's official docs have the **client**
generate the key and "suggest using V4 UUIDs, or another random string with
enough entropy", reused **only** to retry the same request, with a new key per
new operation; OpenAI's commerce spec likewise takes a client-supplied opaque
header. No market leader derives the key from request content.

## Considered Options

- **Content-derived hash (the original design).** Rejected — the pre-spec review
  (2026-06-28) showed it breaks in four ways: (C3/N1) regenerate re-assembles the
  same content ⇒ same key ⇒ within the TTL the server silently dedupes a call
  that is declared "always billable, never silent"; identical duplicate
  messages ("yes" twice) are silently swallowed too. (P1) the two documents
  even disagreed on the hash composition (whole Bot Profile vs its id).
  (M2) hashing needs canonical JSON serialisation, or the key is
  non-deterministic between attempts. And a predictable key lets one guess
  another user's in-flight call. All four vanish with a random key.
- **Random UUID per attempt (chosen).** No canonicalisation, a genuinely new
  generation gets a fresh random key, duplicates are honest, and recovery can
  still ask for the persisted Attempt before re-billing. Less logic than the
  hash, not more.

## Consequences

- **Attempt** becomes the unit of idempotency: minting the key is what starts
  a new billable attempt; silent retries and resend re-use the attempt's key.
- Regenerate of a complete reply / edit / a new turn each mint a new key;
  regenerate of an interrupted reply first recovers under the persisted key
  and mints fresh only for its one `409`/`410` fallback.
- Resend of a `failed` user Message re-uses the original key, so a message
  that *did* quietly arrive isn't processed twice (rule unchanged).
- Server behaviour is unchanged: terminal-TTL `key → status` table, join/await
  an in-flight call, `409 idempotency_conflict` on same-key-different-params —
  which with client-minted UUIDs signals a client bug *in silent retries*
  (see the Amendment below for the explicit-command path, where it is a
  legal, auto-recovered case).
- Review findings C3/N1, P1 and M2 are closed by this decision.

## Amendment (2026-07-10, pre-implementation review)

- **A repeat under a key means exactly one thing — "give me the outcome of
  this Attempt"** — resolved purely by the key record's state: unknown → run,
  `running` → join, `complete` → replay, `aborted` → `410 Gone` while the
  terminal record is retained (an aborted first run may already have spent
  tokens). Terminal TTL expiry intentionally makes the key unknown again;
  this occurs outside the silent-retry window and only an explicit recovery
  can bring the persisted key back.
  There is no recovery-only mode and no probe request (SERVER-CONTRACT.md §6).
- **`409`/`410` handling is split by who retried**: in a silent retry they
  are terminal (`409` = client bug — the Attempt's request is frozen
  byte-identical; `410` = the attempt died server-side, `Failed(upstream)`);
  after an explicit resend or interrupted-reply recovery the client falls back
  **once, automatically,** to a fresh key.
- **The key is persisted on the Message** (`attemptKey`): user Message — the
  send's key; assistant Message — the current/last leg's key, updated through
  the Tool Use Cycle. This is what makes "resend/recovery re-uses the same
  key" survive an app restart. No full request envelope is stored: within a
  live Attempt the Core freezes the immutable `ChatRequest` in memory and
  re-sends exactly it.
- **Replay TTL starts only at a terminal state.** A `running` record has no
  `expiresAt`; after the function owner window elapses, the next observer
  atomically marks it `aborted` and returns `410`. This prevents both deletion
  of a live owner and indefinite joining of a dead one without adding a lease
  service, queue or background worker.

## Amendment (2026-07-12, resend scope)

- **Resend is legal only while the `failed` user Message is the LAST Message
  of the conversation.** An older `failed` user Message with later history is
  a full no-op: no truncation, no state change, no new UUID, no
  checkpoint/backend call. For the legal case nothing here changes: the
  resend still carries the **persisted** `attemptKey`, and an explicit
  `409`/`410` still gets its single automatic fresh-key fallback.

## Amendment (2026-07-10, final money/replay hardening)

- Provider SDK automatic retries are disabled. A key may be released only for
  zero request bytes or the small exact provider-recommended retry allowlist
  pinned in SERVER-CONTRACT §6 (OpenAI retryable rate-limit 429 excluding
  credit/quota errors). Generic 500/502/504, unknown 5xx and every ambiguous
  after-bytes failure become `aborted`/410.
- Firestore stores Attempt metadata and a verified pointer, not the SSE body.
  The short-lived terminal outcome lives in a private GCS object (ADR 0006).
  Success is committed object → SHA verification → Firestore `complete` → client
  terminal; therefore a client never sees `done`/`tool_call` that cannot be
  replayed. Logical `expiresAt` is checked on reads; Firestore TTL/GCS lifecycle
  are cleanup only. Each actual run uses a fresh `runId` path; corrupt/missing
  replay is repaired to `aborted`/410 so explicit recovery is not trapped.

## Amendment (2026-07-14, v1 provider scope)

The active v1 allowlist is OpenAI-only. Anthropic is backlog; a future adapter
must define and fixture its exact release/abort classifications before support
can be enabled. No speculative Anthropic status mapping is active in v1.
