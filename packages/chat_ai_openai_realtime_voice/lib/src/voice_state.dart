// The safe, user-facing surface of a voice session. NOTHING here ever carries
// an ephemeral secret, SDP, Authorization header, prompt/system instructions,
// audio, a raw Realtime event, a response body, a track id or a provider
// message: the UI and any surfaced failure are built only from the enums
// below. A [OpenAIRealtimeVoiceState] holds only a coarse [phase] and an
// optional coarse [failure].
library;

/// How many user turns one session serves.
enum OpenAIRealtimeVoiceMode {
  /// Exactly one user reply, then the assistant's one response, then the
  /// session ends. A new reply needs a brand-new session instance.
  singleTurn,

  /// One connection kept open for many VAD turns until `stop`/`dispose`, a
  /// terminal failure, or transport death.
  conversation,
}

/// The coarse lifecycle phase — the only status the UI shows.
enum OpenAIRealtimeVoicePhase {
  /// No session yet; `start()` has not run.
  idle,

  /// Minting the single ephemeral client secret.
  minting,

  /// Peer connection + signaling + data channel + the one `session.update`
  /// (before the microphone is enabled).
  connecting,

  /// Configured and armed: the microphone is live and the server VAD is
  /// waiting for the user to speak.
  listening,

  /// The user is speaking (server VAD detected speech, including a barge-in
  /// over an assistant response).
  userSpeaking,

  /// The assistant's single response is being generated / played out.
  assistantSpeaking,

  /// Tearing the session down (stop/dispose or an auto-close after a
  /// completed single turn).
  stopping,

  /// Terminal, non-failure end of the session.
  ended,

  /// Terminal failure (see [OpenAIRealtimeVoiceState.failure]).
  failed,
}

/// Stable, coarse failure categories. The ONLY failure information that ever
/// leaves a session — no native description, status body, SDP, secret, raw
/// event or provider message is ever attached.
enum OpenAIRealtimeVoiceFailure {
  /// The single client-secret mint failed (before any media/connection).
  mint,

  /// The one audio-only local capture could not be obtained (includes a
  /// denied microphone permission).
  microphone,

  /// Peer connection / SDP signaling / data-channel open failed before the
  /// session was ready.
  connect,

  /// `session.created`/`session.updated` was not reached, or the session died
  /// during setup.
  session,

  /// A transport failure after the live session was established (money-safe:
  /// terminal once a paid response may have begun — never an auto retry).
  transport,

  /// The active response went idle past `responseIdleTimeout` (money-safe
  /// watchdog): one terminal failure, one best-effort cancel/clear, teardown.
  responseTimeout,

  /// One logical assistant reply asked the app to run more tool legs than the
  /// package's `maxToolTurns` cap (default 5) allows. The over-limit resolver is
  /// never started, no `function_call_output` and no new `response.create` is
  /// sent for it, and the session ends terminally. A money-safe bound on a
  /// runaway tool loop — never an auto retry.
  toolLoopLimit,

  /// The optional output guardrail failed closed inside a REPLACEMENT response
  /// (a second block or a callback exception after the one allowed replacement
  /// was already generated). The current response is cancelled/cleared and the
  /// session ends terminally — no second replacement is ever created.
  guardrail,
}

/// An immutable snapshot the UI renders. No sensitive value is reachable from
/// here — only [phase] and an optional coarse [failure].
class OpenAIRealtimeVoiceState {
  const OpenAIRealtimeVoiceState({required this.phase, this.failure});

  const OpenAIRealtimeVoiceState.idle()
    : phase = OpenAIRealtimeVoicePhase.idle,
      failure = null;

  final OpenAIRealtimeVoicePhase phase;

  /// Set only when [phase] is [OpenAIRealtimeVoicePhase.failed].
  final OpenAIRealtimeVoiceFailure? failure;

  @override
  bool operator ==(Object other) =>
      other is OpenAIRealtimeVoiceState &&
      other.phase == phase &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(phase, failure);

  @override
  String toString() =>
      'OpenAIRealtimeVoiceState(phase: $phase, failure: $failure)';
}
