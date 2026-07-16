---
status: accepted
---

# Short-lived terminal replay outcomes live in private Cloud Storage

Idempotency requires a completed paid Attempt to be replayable for a short TTL,
including replies larger than Firestore's per-document limit. Firestore therefore
stores only Attempt state and a verified pointer; the normalised terminal SSE
outcome lives temporarily at `chat-replays/{uid}/{key}/{runId}.sse` in a private GCS
bucket. This is not durable conversation history: the object exists only for the
idempotency replay window and is removed by lifecycle cleanup.

## Considered Options

- **Store the full outcome in the Firestore idempotency document.** Rejected:
  one large reply can exceed the document limit, silently invalidating the replay
  guarantee exactly after a provider call has been paid.
- **Chunk the outcome across Firestore documents.** Rejected: it adds ordering,
  partial-commit and cleanup machinery while object storage already provides the
  needed byte stream and checksum.
- **Impose a smaller product response limit.** Rejected: that changes the
  approved product to fit an implementation detail.
- **Private GCS object + Firestore pointer (chosen).** Minimal split: Firestore
  remains the concurrency/state authority; GCS holds only replay bytes.

## Consequences

- Success commit order is object terminal → finalize/SHA verification →
  Firestore `complete` → client `done|tool_call`. A success terminal is never
  exposed before its replay artifact is durable.
- A failed object/final commit marks the Attempt `aborted`; the client receives
  `upstream`/EOF and keeps its partial. No second provider call occurs under the
  retained key.
- Replay verifies path, byte count and SHA-256. Joiners wait for Firestore
  terminal state and never read a live partial object.
- Every `unknown → running` execution mints a new `runId` and creates its object
  with a no-overwrite generation precondition. Cleanup addresses the exact old
  path, so delayed cleanup cannot delete a later execution of the same key.
- The same run object also carries a normalised `error` for a released owner.
  It is finalised before the key is deleted, allowing cross-instance joiners that
  captured that `runId` to return the identical cause/Retry-After without taking
  ownership. Only a later client request can start a new run.
- Permanent missing/corrupt replay data atomically changes `complete → aborted`
  and returns 410. The old key never calls the provider, while explicit recovery
  can use its already-approved one fresh-key fallback instead of getting stuck.
- `expiresAt` is checked logically on every request. Firestore TTL and GCS
  lifecycle are cleanup only; delayed physical deletion cannot extend replay
  semantics.
- The bucket is private with Public Access Prevention and service-account-only
  access. Lifecycle/IAM validation is a deployment gate; orphan objects are
  lifecycle-cleaned.
