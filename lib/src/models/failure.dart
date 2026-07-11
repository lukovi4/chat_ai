/// The closed 10-code catalogue of failure causes (CONTEXT.md §Failure,
/// V1_SPEC §5). A machine code, never user-facing text — the app localizes off
/// the code (`failureText` on the Message List, §7). New codes are added here;
/// a strict consumer must handle them, soft consumers (a default branch) are
/// unaffected (V1_SPEC §0). On the wire these ride as kebab-case strings
/// (V1_SPEC §6) — the mapping belongs to the transport layer, not this enum.
enum FailureCause {
  /// 401 — id-token / App Check rejected; "sign in again".
  auth,

  /// 403 — not entitled to the requested Bot Profile / model.
  entitlement,

  /// 402 — over allowance; the app shows a paywall.
  quota,

  /// 429 — too many requests; retry-eligible pre-token within the deadline.
  rate,

  /// Provider overloaded (e.g. 529); retry-eligible pre-token.
  overloaded,

  /// The provider refused the content; never retried.
  contentFilter,

  /// 413 / provider context window exceeded; never retried silently.
  contextTooLong,

  /// Transport failure / no response, after silent retries are exhausted.
  network,

  /// The provider or proxy failed after processing started.
  upstream,

  /// Client-side only: the Tool Use Cycle hit `maxToolTurns` (V1_SPEC §3).
  toolLoopLimit,
}

/// Which side of the first token the reply failed on (V1_SPEC §5):
/// [sending] — before any token arrived; [streaming] — after.
enum FailurePhase { sending, streaming }
