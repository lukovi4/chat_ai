import 'package:freezed_annotation/freezed_annotation.dart';

import '../models/content_part.dart';
import '../models/failure.dart';
import '../models/tool.dart';
import '../models/usage.dart';

part 'backend_event.freezed.dart';

/// Everything a [ChatBackend] can say about one request (V1_SPEC §8).
///
/// **The backend stream never throws** — every outcome, transport failure
/// included, is one of these events ("failures are data" extends to the
/// transport layer); a thrown error escaping `send()` is a bug by contract.
///
/// Each leg's response ends with exactly one terminal event: [ToolCallEvent]
/// (this leg is over; the tool-result comes back as a new request), [DoneEvent]
/// (final leg) or [ErrorEvent]. [ConflictEvent] / [GoneEvent] are protocol
/// signals, not Failure causes: inside a silent retry the Core maps them to
/// `Failed(upstream)` (409 additionally asserts in debug — a frozen request
/// cannot legally conflict); after an explicit command → one automatic
/// fresh-key re-run (V1_SPEC §6).
///
/// `copyWith` is off: the spec-pinned field name `call` (V1_SPEC §8) collides
/// with the generated copyWith's `call` method, and events are consumed via
/// pattern matching, never edited.
@Freezed(copyWith: false)
sealed class BackendEvent with _$BackendEvent {
  /// At most once PER BACKEND REQUEST (a same-key Attempt may see several
  /// across its silent retries), before any other event of that request: a
  /// valid SSE response arrived after the proxy atomically selected one safe
  /// path — create-and-run, join running, or replay complete. Asserts safe
  /// server handling/liveness, NOT proof the provider billed anything. A
  /// pre-stream failure may end the request without [Accepted] ever arriving.
  const factory BackendEvent.accepted() = Accepted;

  /// One visible text chunk of the reply.
  const factory BackendEvent.delta(String text) = Delta;

  /// Hidden provider-continuity state, ordered with the visible deltas/tool
  /// parts; nonterminal. The Core appends it to the assistant Message; it
  /// never reaches the Token Stream or rendering.
  const factory BackendEvent.providerState(ProviderOpaquePart part) =
      ProviderStateEvent;

  /// Terminal event of the current LEG: the bot requests an app Tool;
  /// [usage] carries that leg's usage. No `done` follows in this response.
  const factory BackendEvent.toolCall(ToolCall call, {Usage? usage}) =
      ToolCallEvent;

  /// Terminal event of the FINAL leg; the Core sums all legs' usage into the
  /// reply's `Done(usage)` fact (`usageRaw` kept only for single-leg replies).
  const factory BackendEvent.done({Usage? usage}) = DoneEvent;

  /// Terminal: an operational failure as data. [retryAfter] comes from the
  /// standard `Retry-After` header (pre-stream HTTP) or the `retryAfterMs`
  /// field of the SSE error event — one backoff input, two wires.
  const factory BackendEvent.error(
    FailureCause cause, {
    String? detail,
    Usage? usage,
    Duration? retryAfter,
  }) = ErrorEvent;

  /// HTTP 409 — same key, mismatched params.
  const factory BackendEvent.conflict() = ConflictEvent;

  /// HTTP 410 — the attempt was recorded as aborted server-side.
  const factory BackendEvent.gone() = GoneEvent;
}
