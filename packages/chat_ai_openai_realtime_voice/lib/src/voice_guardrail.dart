// The OPTIONAL output guardrail: its minimal public types plus the
// package-internal scheduler that runs the app's post-generation classifier over
// the assistant transcript of the CURRENT reply.
//
// It is a low-latency POST-generation guardrail, NOT premoderation: it never
// buffers the whole reply and never delays audio waiting for a verdict. Part of
// the audio may already have played by the time a block is decided (see the
// package docs). On the FIRST block or callback exception the session fails
// closed (cancel / clear / interrupted recording / one coarse event / one
// no-context replacement). A block inside the one allowed replacement is
// terminal.
//
// Privacy: the coarse [OpenAIRealtimeVoiceGuardrailEvent] carries ONLY the local
// turnId — never the text, the classifier reason, provider ids or any raw
// detail. The accumulated transcript is passed to the app callback but is never
// logged or stored by the package.
// ignore_for_file: prefer_initializing_formals
library;

import 'dart:async';

/// The classifier's verdict for one accumulated-transcript check.
enum OpenAIRealtimeVoiceGuardrailDecision {
  /// Let the current assistant reply continue.
  allow,

  /// Block the current assistant reply (the session fails closed).
  block,
}

/// The app's output guardrail callback. Given the CURRENT reply's local
/// [turnId] and the transcript accumulated so far ([accumulatedText]), it
/// returns a [OpenAIRealtimeVoiceGuardrailDecision]. It is invoked at most once
/// at a time and at most once per 250 ms; the same final transcript is always
/// checked once before the reply completes.
typedef OpenAIRealtimeVoiceOutputGuardrail =
    Future<OpenAIRealtimeVoiceGuardrailDecision> Function({
      required String turnId,
      required String accumulatedText,
    });

/// The single coarse event emitted when the output guardrail blocks a reply. It
/// carries ONLY the local [turnId] — never the text, the classifier reason,
/// provider ids or any raw detail.
class OpenAIRealtimeVoiceGuardrailEvent {
  const OpenAIRealtimeVoiceGuardrailEvent({required this.turnId});

  /// The LOCAL reply id (UUID v4) that was blocked. Never an OpenAI id.
  final String turnId;

  @override
  bool operator ==(Object other) =>
      other is OpenAIRealtimeVoiceGuardrailEvent && other.turnId == turnId;

  @override
  int get hashCode => turnId.hashCode;

  @override
  String toString() => 'OpenAIRealtimeVoiceGuardrailEvent(turnId: $turnId)';
}

/// The timer seam for the fixed 250 ms throttle (structurally the session's
/// watchdog timer factory), so tests drive the schedule with a deterministic
/// fake clock. Not a public setting.
typedef GuardrailTimerFactory =
    Timer Function(Duration duration, void Function() onTimeout);

/// The package-internal scheduler around one app [OpenAIRealtimeVoiceOutputGuardrail].
///
/// Contract, per logical assistant reply:
/// - accumulates the exact transcript from the reply's valid deltas;
/// - runs a check at most once per 250 ms and never two callbacks at once;
/// - if new text arrives during a callback it is checked after that callback;
/// - the final transcript is always checked once, and never in parallel with a
///   running check; the reply's completion waits for that final check;
/// - a late callback result after a new turn / cancel / dispose is inert;
/// - the FIRST block (or a callback exception) calls [onViolation] exactly once
///   for that turn; the scheduler then stops checking that turn.
class OutputGuardrailRunner {
  OutputGuardrailRunner({
    required OpenAIRealtimeVoiceOutputGuardrail guardrail,
    required GuardrailTimerFactory timerFactory,
    required void Function(String turnId) onViolation,
  }) : _guardrail = guardrail,
       _timerFactory = timerFactory,
       _onViolation = onViolation;

  static const Duration _throttle = Duration(milliseconds: 250);

  final OpenAIRealtimeVoiceOutputGuardrail _guardrail;
  final GuardrailTimerFactory _timerFactory;
  final void Function(String turnId) _onViolation;

  String? _turnId; // the reply currently under guardrail (null between replies)
  final StringBuffer _text = StringBuffer();
  // A PHYSICAL app callback is currently awaiting. It is set at a callback start
  // and cleared only when that callback actually resolves/errors — NEVER by
  // beginTurn/cancelTurn/dispose. This is what guarantees at most one app
  // callback runs at a time across the whole session, even across turn changes
  // (defect 7): a new turn's check waits until the old physical callback ends.
  bool _inFlight = false;
  bool _dirty = false; // text changed since the last check START
  Timer? _cooldown; // non-null during the 250 ms window since a check START
  bool _violated = false; // a block/exception fired for the current turn

  bool _finalRequested = false;
  // The authoritative exact final transcript for the current turn (from
  // response.output_audio_transcript.done); the mandatory final check uses it
  // verbatim instead of the accumulated deltas (defect 6).
  String? _finalText;
  Completer<bool>? _finalCompleter;

  bool _disposed = false;

  /// Starts a fresh guardrail context for a new logical assistant reply (or the
  /// replacement). Any in-flight callback of a previous turn becomes inert.
  void beginTurn(String turnId) {
    if (_disposed) {
      return;
    }
    _turnId = turnId;
    _text.clear();
    // Do NOT reset _inFlight: an old turn's app callback may still be physically
    // running; it will finish, be treated as stale, and only THEN free the slot.
    _dirty = false;
    _cooldown?.cancel();
    _cooldown = null;
    _violated = false;
    _finalRequested = false;
    _finalText = null;
    // A finalize() awaiting an OLD turn (never awaited here) is not carried over;
    // the session only awaits the turn it just completed.
    _finalCompleter = null;
  }

  /// Feeds one validated assistant transcript delta of [turnId]. Ignored unless
  /// it belongs to the current, not-yet-violated turn.
  void addDelta(String turnId, String delta) {
    if (_disposed || _violated || _turnId != turnId) {
      return;
    }
    _text.write(delta);
    _dirty = true;
    _pump();
  }

  /// Drops the current guardrail context (barge-in / interrupt / abandon /
  /// terminal). A pending finalize resolves as allowed (nothing to block), and
  /// any in-flight callback becomes LOGICALLY stale — but is NOT declared
  /// physically finished (its slot frees only when it truly resolves).
  void cancelTurn() {
    if (_disposed) {
      return;
    }
    _turnId = null;
    _text.clear();
    // Do NOT reset _inFlight — see beginTurn.
    _dirty = false;
    _cooldown?.cancel();
    _cooldown = null;
    _finalRequested = false;
    _finalText = null;
    final c = _finalCompleter;
    _finalCompleter = null;
    if (c != null && !c.isCompleted) {
      c.complete(true);
    }
  }

  /// Runs the mandatory final check for [turnId] against the AUTHORITATIVE exact
  /// [finalText] (from response.output_audio_transcript.done), and completes when
  /// it is done. Returns true if the reply is clean (allowed), false if it was
  /// blocked (a violation was already reported via [onViolation]). If [turnId] is
  /// not the current turn, there is nothing to finalize and it resolves true.
  Future<bool> finalize(String turnId, {required String finalText}) {
    if (_disposed || _turnId != turnId) {
      return Future<bool>.value(true);
    }
    if (_violated) {
      return Future<bool>.value(false);
    }
    _finalText = finalText;
    _finalRequested = true;
    final completer = _finalCompleter ??= Completer<bool>();
    _pumpFinal();
    return completer.future;
  }

  void dispose() {
    _disposed = true;
    _cooldown?.cancel();
    _cooldown = null;
    final c = _finalCompleter;
    _finalCompleter = null;
    if (c != null && !c.isCompleted) {
      c.complete(true);
    }
  }

  // ---- scheduling ---------------------------------------------------------

  void _pump() {
    if (_disposed || _violated || _turnId == null || _inFlight) {
      return;
    }
    if (_finalRequested) {
      // The mandatory final check bypasses the 250 ms cooldown (but never runs
      // in parallel with a physically-running callback).
      _startCheck(isFinal: true);
      return;
    }
    if (_cooldown != null) {
      // Rate-limited: the cooldown callback re-pumps.
      return;
    }
    if (_dirty) {
      _startCheck(isFinal: false);
    }
  }

  void _pumpFinal() {
    if (_disposed || _violated) {
      _completeFinal();
      return;
    }
    if (_inFlight) {
      return; // wait for the physically-running callback; its resolution re-pumps
    }
    _startCheck(isFinal: true);
  }

  void _startCheck({required bool isFinal}) {
    final turnId = _turnId!;
    _inFlight = true;
    _dirty = false;
    if (!isFinal) {
      // Leading-edge throttle: the 250 ms window opens at the check START.
      _cooldown = _timerFactory(_throttle, () {
        _cooldown = null;
        _pump();
      });
    }
    // The mandatory final check uses the authoritative exact final transcript;
    // periodic checks use the accumulated deltas.
    final text = isFinal && _finalText != null ? _finalText! : _text.toString();
    Future<OpenAIRealtimeVoiceGuardrailDecision> future;
    try {
      future = _guardrail(turnId: turnId, accumulatedText: text);
    } catch (_) {
      // A synchronous throw from the callback is a fail-closed violation.
      _onCallbackError(turnId, isFinal);
      return;
    }
    future.then(
      (decision) => _onResult(turnId, isFinal, decision),
      onError: (Object _) => _onCallbackError(turnId, isFinal),
    );
  }

  void _onResult(
    String turnId,
    bool isFinal,
    OpenAIRealtimeVoiceGuardrailDecision decision,
  ) {
    // The physical callback has resolved — free the single callback slot.
    _inFlight = false;
    if (_disposed) {
      return;
    }
    if (_turnId != turnId || _violated) {
      // Stale (a new/cancelled turn) or already-violated: touch no turn state,
      // but let the CURRENT turn proceed now that the slot is free (defect 7).
      _pump();
      return;
    }
    if (decision == OpenAIRealtimeVoiceGuardrailDecision.block) {
      _violate(turnId);
      return;
    }
    if (isFinal) {
      _completeFinal();
      return;
    }
    if (_finalRequested) {
      _pumpFinal();
    } else {
      _pump();
    }
  }

  void _onCallbackError(String turnId, bool isFinal) {
    _inFlight = false;
    if (_disposed) {
      return;
    }
    if (_turnId != turnId || _violated) {
      _pump(); // stale/late error of a superseded turn — free the slot, proceed
      return;
    }
    // A callback exception fails closed exactly like a block.
    _violate(turnId);
  }

  void _violate(String turnId) {
    _violated = true;
    _cooldown?.cancel();
    _cooldown = null;
    // Complete a waiting final check FIRST (with `false`, since _violated is now
    // true) so the session's completion path never closes a blocked turn, THEN
    // hand off the fail-closed to the session. onViolation must not touch the
    // completer.
    _completeFinal();
    _onViolation(turnId);
  }

  void _completeFinal() {
    final c = _finalCompleter;
    _finalRequested = false;
    _finalCompleter = null;
    if (c != null && !c.isCompleted) {
      c.complete(!_violated);
    }
  }
}
