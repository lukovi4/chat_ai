// Safe, user-facing state of the voice probe. NOTHING here ever carries a
// secret, SDP, Realtime event, transcript, audio byte, track id or file path:
// the UI and any surfaced error are built only from the enums/handles below.
library;

/// Stable, coarse error codes. The ONLY failure information that ever leaves
/// the probe — no native description, track id, path, status body or raw
/// exception is ever attached.
enum VoiceProbeErrorCode {
  /// The single client-secret mint failed (before any media/connection).
  mintFailed,

  /// The one audio-only local capture could not be obtained (includes a
  /// denied microphone permission).
  micUnavailable,

  /// Peer connection / SDP signaling / data-channel open failed before the
  /// session was ready.
  connectFailed,

  /// `session.created`/`session.updated` was not reached, or the session died
  /// during setup.
  sessionFailed,

  /// A native audio writer could not start, or finalized to an empty /
  /// unplayable / zero-duration file.
  writerFailed,

  /// A network/transport failure after the point a paid response may have
  /// begun — terminal by money-safe rule (no auto retry/reconnect).
  transportLost,

  /// The iOS audio session could not be configured (coarse; no native detail).
  audioSessionFailed,

  /// Any other internal probe failure (still carries no detail).
  internal,
}

/// Stable, coarse per-writer finalize status. No raw OSStatus / native
/// exception / path / track id is ever attached.
enum WriterStatus {
  /// Finalized a valid, non-empty, playable file.
  ok,

  /// The renderer received no buffers at all.
  noCallbacks,

  /// Buffers arrived but nothing was written to the file.
  noFrames,

  /// The output file could not be created / configured.
  fileFailed,

  /// The written file did not re-open as valid non-zero-duration audio.
  validationFailed,

  /// The writer was already closed when finalize was requested.
  writerClosed,

  /// Any other writer failure (still carries no detail).
  unknown,
}

/// Minimal, content-free diagnostics for one writer (shown in the probe UI
/// after Stop/failure only). Counters + a stable status; never a path / track
/// id / OSStatus / audio bytes.
class WriterDiagnostics {
  const WriterDiagnostics({
    required this.callbackCount,
    required this.writtenFrames,
    required this.status,
  });

  final int callbackCount;
  final int writtenFrames;
  final WriterStatus status;
}

/// The per-attempt diagnostic snapshot: the two writers' minimal diagnostics
/// plus four safe lifecycle booleans decoded from the `oai-events` stream. No
/// raw event, payload, transcript or audio ever reaches here.
class VoiceProbeDiagnostics {
  const VoiceProbeDiagnostics({
    this.user,
    this.assistant,
    this.responseCreated = false,
    this.outputAudioStarted = false,
    this.outputAudioStopped = false,
    this.responseDone = false,
  });

  final WriterDiagnostics? user;
  final WriterDiagnostics? assistant;
  final bool responseCreated;
  final bool outputAudioStarted;
  final bool outputAudioStopped;
  final bool responseDone;

  /// True once the assistant's single response is finished — the UI shows the
  /// user may press Stop. Stop is never invoked automatically.
  bool get responseFinished => outputAudioStopped || responseDone;

  VoiceProbeDiagnostics copyWith({
    WriterDiagnostics? user,
    WriterDiagnostics? assistant,
    bool? responseCreated,
    bool? outputAudioStarted,
    bool? outputAudioStopped,
    bool? responseDone,
  }) {
    return VoiceProbeDiagnostics(
      user: user ?? this.user,
      assistant: assistant ?? this.assistant,
      responseCreated: responseCreated ?? this.responseCreated,
      outputAudioStarted: outputAudioStarted ?? this.outputAudioStarted,
      outputAudioStopped: outputAudioStopped ?? this.outputAudioStopped,
      responseDone: responseDone ?? this.responseDone,
    );
  }
}

/// One finalized, validated, playable artifact. Carries an OPAQUE native
/// handle and a duration only — never the file path.
class VoiceProbeArtifact {
  const VoiceProbeArtifact({required this.handle, required this.durationMs});

  /// Opaque native writer handle used to drive playback; not a path.
  final String handle;

  /// Validated non-zero duration in milliseconds.
  final int durationMs;
}

/// The two published artifacts of one probe turn (only ever set together,
/// after both writers finalize successfully).
class VoiceProbeArtifacts {
  const VoiceProbeArtifacts({required this.user, required this.assistant});

  final VoiceProbeArtifact user;
  final VoiceProbeArtifact assistant;
}

/// The coarse lifecycle phase — the only status text the UI shows.
enum VoiceProbePhase {
  /// No session; Start is allowed.
  idle,

  /// Minting the single client secret.
  minting,

  /// Acquiring the audio-only local capture.
  capturing,

  /// Peer connection + signaling + data channel.
  connecting,

  /// Session created; sending/awaiting the one `session.update`.
  configuring,

  /// Writers armed, local track enabled — the user should speak one phrase.
  speak,

  /// The user's phrase ended; the assistant's single response is playing.
  responding,

  /// Finalizing + validating both writers on Stop/Close.
  finalizing,

  /// Both artifacts finalized and published; Play buttons available.
  ready,

  /// Terminal failure (see [VoiceProbeState.errorCode]).
  failed,

  /// The session was cancelled/closed before completion.
  closed,
}

/// An immutable snapshot the UI renders. No sensitive value is reachable
/// from here.
class VoiceProbeState {
  const VoiceProbeState({
    required this.phase,
    this.errorCode,
    this.artifacts,
    this.diagnostics,
  });

  const VoiceProbeState.idle()
    : phase = VoiceProbePhase.idle,
      errorCode = null,
      artifacts = null,
      diagnostics = null;

  final VoiceProbePhase phase;

  /// Set only when [phase] is [VoiceProbePhase.failed].
  final VoiceProbeErrorCode? errorCode;

  /// Set only when [phase] is [VoiceProbePhase.ready].
  final VoiceProbeArtifacts? artifacts;

  /// The safe per-attempt diagnostic snapshot (event booleans + the two
  /// writers' minimal diagnostics). Populated during a live attempt and after
  /// Stop/failure; never carries raw detail.
  final VoiceProbeDiagnostics? diagnostics;

  /// Start is offered only with no active session.
  bool get canStart =>
      phase == VoiceProbePhase.idle ||
      phase == VoiceProbePhase.failed ||
      phase == VoiceProbePhase.closed ||
      phase == VoiceProbePhase.ready;

  /// Stop/Close is offered while a session is live.
  bool get canStop => !canStart && phase != VoiceProbePhase.finalizing;

  /// Playback is offered only once artifacts are published.
  bool get canPlay => phase == VoiceProbePhase.ready && artifacts != null;

  VoiceProbeState copyWith({
    VoiceProbePhase? phase,
    VoiceProbeErrorCode? errorCode,
    VoiceProbeArtifacts? artifacts,
    VoiceProbeDiagnostics? diagnostics,
  }) {
    return VoiceProbeState(
      phase: phase ?? this.phase,
      errorCode: errorCode ?? this.errorCode,
      artifacts: artifacts ?? this.artifacts,
      diagnostics: diagnostics ?? this.diagnostics,
    );
  }
}
