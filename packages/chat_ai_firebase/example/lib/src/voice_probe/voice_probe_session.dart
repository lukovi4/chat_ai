// The voice probe's single-turn state machine and money-safe coordinator
// (Increment-0 iOS spike). It owns the lifecycle, enforces one-mint /
// one-response / no-retry / no-reconnect, arms the two native writers, and
// publishes playable artifacts only after both finalize successfully.
//
// Nothing sensitive is ever surfaced: state carries only a coarse phase, a
// stable error code and opaque artifact handles.
//
// Attempt isolation + settlement barrier: every Start captures a monotonic
// [_attempt] id AND a per-attempt [_AttemptBarrier]. The barrier tracks the
// attempt's in-flight async work (the start/connect body and a running
// _armAndSpeak) and only "settles" once the attempt is terminal AND all that
// work has actually finished — including a connect() that was still pending
// (with its late adopt/close) when Stop cancelled. A new Start is refused until
// the previous attempt has settled, so a cancelled-but-not-yet-settled attempt
// can never let a second mint through. Stop never blocks on that settlement.
// Every barrier enter/leave/markTerminal is threaded on the attempt it belongs
// to, so a stale continuation touches only its own (dead) barrier and flags,
// never a newer attempt's.
// Public named constructor parameters assign private fields (harness
// convention): a private named initializing formal is not an option.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart'
    show ClientSecretProvider;

import 'native_audio_writer.dart';
import 'probe_cancellation.dart';
import 'probe_release.dart';
import 'probe_state.dart';
import 'session_update.dart';
import 'voice_probe_transport.dart';

/// Builds one fresh transport per Start (nothing is pooled or reused).
typedef VoiceProbeTransportFactory = VoiceProbeTransport Function();

/// A minimal, per-attempt settlement barrier. It completes [done] only once the
/// attempt is [markTerminal]-ed AND every entered async unit has [leave]-d —
/// i.e. no start/connect continuation or arming is still running. Not a session
/// framework; just a local join for one probe attempt.
class _AttemptBarrier {
  int _inFlight = 0;
  bool _terminal = false;
  final Completer<void> _done = Completer<void>();

  Future<void> get done => _done.future;
  bool get isSettled => _done.isCompleted;

  void enter() => _inFlight++;

  void leave() {
    if (_inFlight > 0) {
      _inFlight--;
    }
    _check();
  }

  void markTerminal() {
    _terminal = true;
    _check();
  }

  void _check() {
    if (_terminal && _inFlight == 0 && !_done.isCompleted) {
      _done.complete();
    }
  }
}

class VoiceProbeSession {
  VoiceProbeSession({
    required ClientSecretProvider clientSecretProvider,
    required String botId,
    required VoiceProbeTransportFactory transportFactory,
    required NativeAudioWriterFactory writerFactory,
  }) : _provider = clientSecretProvider,
       _botId = botId,
       _transportFactory = transportFactory,
       _writerFactory = writerFactory;

  final ClientSecretProvider _provider;
  final String _botId;
  final VoiceProbeTransportFactory _transportFactory;
  final NativeAudioWriterFactory _writerFactory;

  final StreamController<VoiceProbeState> _states =
      StreamController<VoiceProbeState>.broadcast();
  VoiceProbeState _state = const VoiceProbeState.idle();

  // Monotonic attempt id; every async continuation carries the attempt it was
  // spawned for and no-ops once it is no longer current.
  int _attempt = 0;

  // The current/last attempt's settlement barrier. A new Start is refused while
  // this exists and has not settled.
  _AttemptBarrier? _barrier;

  // Per-Start session context. Non-null only while a session is live (or a
  // successful result's writers are still held for playback).
  bool _active = false;
  ProbeCancellation? _cancellation;
  ProbeRelease? _release;
  VoiceProbeTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _eventsSub;
  NativeAudioWriter? _userWriter;
  NativeAudioWriter? _assistantWriter;
  Future<void>? _teardown;

  bool _sessionUpdateSent = false;
  bool _arming = false;
  bool _armed = false;
  bool _userTurnEnded = false;
  bool _responseActive = false;
  bool _responseCancelSent = false;

  // Safe lifecycle booleans decoded from the event stream (no raw payload).
  bool _responseCreated = false;
  bool _outputAudioStarted = false;
  bool _outputAudioStopped = false;
  bool _responseDone = false;
  WriterDiagnostics? _userDiag;
  WriterDiagnostics? _assistantDiag;

  VoiceProbeState get state => _state;
  Stream<VoiceProbeState> get states => _states.stream;

  /// The current per-attempt diagnostic snapshot attached to every emitted
  /// state — event booleans plus (after finalize) the two writers' minimal
  /// diagnostics.
  VoiceProbeDiagnostics get _diagnostics => VoiceProbeDiagnostics(
    user: _userDiag,
    assistant: _assistantDiag,
    responseCreated: _responseCreated,
    outputAudioStarted: _outputAudioStarted,
    outputAudioStopped: _outputAudioStopped,
    responseDone: _responseDone,
  );

  void _emit(VoiceProbeState next) {
    _state = next;
    if (!_states.isClosed) {
      _states.add(next);
    }
  }

  void _setPhase(VoiceProbePhase phase) =>
      _emit(VoiceProbeState(phase: phase, diagnostics: _diagnostics));

  bool _isCurrent(int attempt) => attempt == _attempt;

  bool _cancelled(ProbeCancellation cancellation) => cancellation.isCancelled;

  /// One manual Start. Rejected synchronously (before the provider is ever
  /// called) if a session is active OR the previous attempt has not fully
  /// settled — no concurrent/duplicate mint.
  Future<void> start() async {
    if (_active) {
      return;
    }
    final previous = _barrier;
    if (previous != null && !previous.isSettled) {
      // A cancelled-but-still-settling attempt (e.g. a connect that is still
      // pending its late adopt/close) blocks a new mint until it settles.
      return;
    }

    _active = true;
    final attempt = ++_attempt;
    final barrier = _AttemptBarrier();
    _barrier = barrier;
    barrier.enter(); // the start/connect body

    // Explicit end-of-life for a previous successful result's writers BEFORE a
    // new mint: their native files/players are released here, never merely
    // dropped as Dart references.
    await _closeHeldWriters();

    _resetTurnFlags();
    final cancellation = ProbeCancellation();
    final release = ProbeRelease();
    _cancellation = cancellation;
    _release = release;
    _teardown = null;

    _setPhase(VoiceProbePhase.minting);
    try {
      // Exactly one client-secret mint per Start.
      final secret = await _provider.getClientSecret(botId: _botId);
      if (!_isCurrent(attempt) || _cancelled(cancellation)) {
        throw const VoiceProbeConnectCancelled();
      }

      _setPhase(VoiceProbePhase.connecting);
      final transport = _transportFactory();
      _transport = transport;
      await release.register(transport.close);

      // Subscribe BEFORE connect can accept the first DataChannel message, so
      // an early session.created (delivered on the broadcast stream during
      // connect) is never dropped. No replay/buffering is added.
      _eventsSub = transport.events.listen(
        (event) => _onEvent(attempt, barrier, event),
        onDone: () => _onEventsDone(attempt),
        onError: (_) {},
      );

      await transport.connect(secret, cancellation);
      if (!_isCurrent(attempt) || _cancelled(cancellation)) {
        throw const VoiceProbeConnectCancelled();
      }
    } on VoiceProbeMicException {
      await _failAndTeardown(attempt, VoiceProbeErrorCode.micUnavailable);
    } on VoiceProbeConnectCancelled {
      await _cancelAndTeardown(attempt);
    } on VoiceProbeConnectException {
      await _failAndTeardown(attempt, VoiceProbeErrorCode.connectFailed);
    } catch (_) {
      // The mint provider's own sanitized exception surfaces here; classified
      // by phase with no detail retained.
      if (_state.phase == VoiceProbePhase.minting) {
        await _failAndTeardown(attempt, VoiceProbeErrorCode.mintFailed);
      } else {
        await _failAndTeardown(attempt, VoiceProbeErrorCode.connectFailed);
      }
    } finally {
      // The start/connect body (and any connect that only settled after a
      // mid-flight cancel, with its late adopt/close) is done: release its hold
      // on the barrier. Once arming is also done and the attempt is terminal,
      // the barrier settles and a new Start is allowed.
      barrier.leave();
    }
  }

  Future<void> _onEvent(
    int attempt,
    _AttemptBarrier barrier,
    Map<String, Object?> event,
  ) async {
    if (!_isCurrent(attempt)) {
      return;
    }
    final type = event['type'];
    if (type is! String) {
      return;
    }
    switch (type) {
      case 'session.created':
        await _sendSessionUpdateOnce(attempt);
      case 'session.updated':
        await _armAndSpeak(attempt, barrier);
      case 'input_audio_buffer.speech_stopped':
        _endUserTurn(attempt);
      case 'response.created':
        // The server accepted the turn — NOT proof output audio started.
        _responseCreated = true;
        _responseActive = true;
        if (_armed) {
          _setPhase(VoiceProbePhase.responding);
        }
      case 'output_audio_buffer.started':
        // The server actually began transmitting output audio.
        _outputAudioStarted = true;
        _responseActive = true;
        if (_armed) {
          _setPhase(VoiceProbePhase.responding);
        }
      case 'output_audio_buffer.stopped':
        _outputAudioStopped = true;
        _responseActive = false;
        if (_armed) {
          // The response is finished; the UI invites Stop (never automatic).
          _setPhase(VoiceProbePhase.responding);
        }
      case 'response.done':
        _responseDone = true;
        _responseActive = false;
        if (_armed) {
          _setPhase(VoiceProbePhase.responding);
        }
      case 'error':
        // A sanitized terminal error: nothing from the raw event (message,
        // code, param, event_id) is ever stored or shown. No retry/mint.
        if (_armed &&
            (_responseActive ||
                _state.phase == VoiceProbePhase.responding ||
                _state.phase == VoiceProbePhase.speak)) {
          await _failAndTeardown(attempt, VoiceProbeErrorCode.transportLost);
        } else {
          await _failAndTeardown(attempt, VoiceProbeErrorCode.sessionFailed);
        }
    }
  }

  Future<void> _sendSessionUpdateOnce(int attempt) async {
    if (!_isCurrent(attempt) || _sessionUpdateSent) {
      return;
    }
    _sessionUpdateSent = true;
    if (_state.phase == VoiceProbePhase.connecting) {
      _setPhase(VoiceProbePhase.configuring);
    }
    final transport = _transport;
    if (transport == null) {
      return;
    }
    // Exactly one session.update; the server VAD creates the one response.
    await transport.send(buildVoiceProbeSessionUpdate());
  }

  Future<void> _armAndSpeak(int attempt, _AttemptBarrier barrier) async {
    if (!_isCurrent(attempt) || _arming || _armed) {
      return;
    }
    _arming = true;
    barrier.enter(); // arming is in-flight work of this attempt
    final transport = _transport;
    final cancellation = _cancellation;
    if (transport == null || cancellation == null) {
      _arming = false;
      barrier.leave();
      return;
    }
    try {
      // The remote track must arrive (or the attempt be cancelled / the
      // transport die) before we commit any paid capture. This wait is
      // cancellable — it never hangs past teardown.
      final remoteId = await _awaitRemoteOrCancel(transport, cancellation);
      if (!_isCurrent(attempt) || _cancelled(cancellation)) {
        return;
      }

      // Arm the user writer first; only its start makes it worth closing.
      final userWriter = _writerFactory.create(isRemote: false);
      _userWriter = userWriter;
      await userWriter.start(trackId: transport.localAudioTrackId);
      if (!_isCurrent(attempt) || _cancelled(cancellation)) {
        return;
      }

      final assistantWriter = _writerFactory.create(isRemote: true);
      _assistantWriter = assistantWriter;
      await assistantWriter.start(trackId: remoteId);
      if (!_isCurrent(attempt) || _cancelled(cancellation)) {
        return;
      }

      // Configure the iOS audio session (capture + playout route) BEFORE the
      // local track is enabled and before any response, so the remote voice is
      // actually audible.
      await transport.configureAudioSession();
      if (!_isCurrent(attempt) || _cancelled(cancellation)) {
        return;
      }

      // Both writers armed → NOW enable the one local track and mark armed.
      transport.setLocalTrackEnabled(true);
      _armed = true;
      _setPhase(VoiceProbePhase.speak);
    } on VoiceProbeConnectCancelled {
      // Cancelled while waiting/arming: the teardown owner (Stop / failure)
      // drives the terminal state; do nothing here.
    } on VoiceProbeAudioSessionException {
      if (_isCurrent(attempt) && !_cancelled(cancellation)) {
        await _failAndTeardown(attempt, VoiceProbeErrorCode.audioSessionFailed);
      }
    } on VoiceProbeWriterException {
      if (_isCurrent(attempt) && !_cancelled(cancellation)) {
        await _failAndTeardown(attempt, VoiceProbeErrorCode.writerFailed);
      }
    } catch (_) {
      if (_isCurrent(attempt) && !_cancelled(cancellation)) {
        await _failAndTeardown(attempt, VoiceProbeErrorCode.sessionFailed);
      }
    } finally {
      // Guarded so a stale attempt's arming can never reset a newer attempt's
      // flag, then release this attempt's arming hold on the barrier.
      if (_isCurrent(attempt)) {
        _arming = false;
      }
      barrier.leave();
    }
  }

  /// Completes with the remote audio track id, or errors with
  /// [VoiceProbeConnectCancelled] on cancel / transport death. A late remote
  /// completion after cancel is ignored (the completer is already settled), so
  /// no writer is armed and the state never moves to speak.
  Future<String> _awaitRemoteOrCancel(
    VoiceProbeTransport transport,
    ProbeCancellation cancellation,
  ) {
    final completer = Completer<String>();
    transport.remoteAudioTrackId
        .then((id) {
          if (!completer.isCompleted) {
            completer.complete(id);
          }
        })
        .catchError((Object _) {
          if (!completer.isCompleted) {
            completer.completeError(const VoiceProbeConnectCancelled());
          }
        });
    cancellation.whenCancelled.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const VoiceProbeConnectCancelled());
      }
    });
    return completer.future;
  }

  void _endUserTurn(int attempt) {
    if (!_isCurrent(attempt) || _userTurnEnded) {
      return;
    }
    _userTurnEnded = true;
    // Disable the local track on the FIRST speech_stopped so the probe can
    // never open a second user turn within this session.
    _transport?.setLocalTrackEnabled(false);
    if (_armed) {
      _setPhase(VoiceProbePhase.responding);
    }
  }

  void _onEventsDone(int attempt) {
    // The session died (EOF). No reconnect, no retry. If a paid response may
    // have started it is a terminal transport loss; during setup it is a
    // session failure. A death after a terminal/ready state is ignored.
    if (!_isCurrent(attempt) || !_active) {
      return;
    }
    if (_state.phase == VoiceProbePhase.speak ||
        _state.phase == VoiceProbePhase.responding) {
      unawaited(_failAndTeardown(attempt, VoiceProbeErrorCode.transportLost));
    } else if (_state.phase == VoiceProbePhase.configuring ||
        _state.phase == VoiceProbePhase.connecting) {
      unawaited(_failAndTeardown(attempt, VoiceProbeErrorCode.sessionFailed));
    }
  }

  /// The one manual Stop/Close. If the writers were armed it finalizes both
  /// (tracks still alive), tears the WebRTC session down exactly once, and
  /// publishes the two playable artifacts only if both finalized validly. If
  /// Stop happens before arming, it is a plain cancel → closed. Stop never
  /// waits on a pending connect — it completes `closed` and the barrier holds a
  /// new Start off until that connect actually settles.
  Future<void> stop() => _teardown ??= _stopOnce(_attempt);

  Future<void> _stopOnce(int attempt) async {
    if (!_active) {
      return;
    }
    _cancellation?.cancel();

    if (!_armed) {
      // Early close (includes Stop while still awaiting the remote track):
      // nothing paid to finalize; any single already-started writer is closed.
      await _cancelResourcesAndClose(VoiceProbePhase.closed);
      return;
    }

    _setPhase(VoiceProbePhase.finalizing);
    // Freeze capture and, if a response is still streaming, one best-effort
    // cancel + clear (both are free control messages) before teardown.
    _transport?.setLocalTrackEnabled(false);
    await _bestEffortCancelActiveResponse();

    // Finalize each writer INDEPENDENTLY while the tracks/renderers still exist —
    // a user-writer failure must never skip the assistant writer, and both
    // results (with diagnostics) are always known.
    final userResult = await _finalizeIndependently(_userWriter);
    final assistantResult = await _finalizeIndependently(_assistantWriter);
    _userDiag = userResult?.diagnostics;
    _assistantDiag = assistantResult?.diagnostics;

    final bothOk =
        userResult != null &&
        assistantResult != null &&
        userResult.ok &&
        assistantResult.ok &&
        userResult.artifact != null &&
        assistantResult.artifact != null;

    // Tear down the WebRTC session exactly once (writers already finalized
    // their files; teardown never touches them).
    await _releaseWebRtc();

    if (bothOk) {
      // Keep the writers alive for Play; they are released on the next Start or
      // dispose. The session is no longer "active" so a new Start is allowed.
      _active = false;
      _emit(
        VoiceProbeState(
          phase: VoiceProbePhase.ready,
          artifacts: VoiceProbeArtifacts(
            user: userResult.artifact!,
            assistant: assistantResult.artifact!,
          ),
          diagnostics: _diagnostics,
        ),
      );
    } else {
      // Any invalid writer → failed; both writers close exactly once, and the
      // safe per-writer diagnostics stay visible.
      await _closeHeldWriters();
      _active = false;
      _emit(
        VoiceProbeState(
          phase: VoiceProbePhase.failed,
          errorCode: VoiceProbeErrorCode.writerFailed,
          diagnostics: _diagnostics,
        ),
      );
    }
    // Terminal reached; the barrier settles once the (already-finished) start
    // body and any arming have left.
    _barrier?.markTerminal();
  }

  /// Finalizes one writer, isolating its outcome so a failure in one never
  /// prevents the other from being finalized. Never throws.
  Future<WriterFinalizeResult?> _finalizeIndependently(
    NativeAudioWriter? writer,
  ) async {
    if (writer == null) {
      return null;
    }
    try {
      return await writer.finalize();
    } catch (_) {
      return const WriterFinalizeResult(
        ok: false,
        diagnostics: WriterDiagnostics(
          callbackCount: 0,
          writtenFrames: 0,
          status: WriterStatus.unknown,
        ),
      );
    }
  }

  Future<void> _bestEffortCancelActiveResponse() async {
    if (!_responseActive || _responseCancelSent) {
      return;
    }
    _responseCancelSent = true;
    final transport = _transport;
    if (transport == null) {
      return;
    }
    try {
      await transport.send(<String, Object?>{'type': 'response.cancel'});
      await transport.send(<String, Object?>{
        'type': 'output_audio_buffer.clear',
      });
    } catch (_) {
      // Best-effort only; teardown proceeds regardless.
    }
  }

  /// Plays the finalized user capture by opaque handle.
  Future<void> playUser() => _playArtifact(_state.artifacts?.user);

  /// Plays the finalized assistant response by opaque handle.
  Future<void> playAssistant() => _playArtifact(_state.artifacts?.assistant);

  Future<void> _playArtifact(VoiceProbeArtifact? artifact) async {
    if (artifact == null) {
      return;
    }
    final writer = artifact.handle == _userWriter?.writerId
        ? _userWriter
        : artifact.handle == _assistantWriter?.writerId
        ? _assistantWriter
        : null;
    try {
      await writer?.play();
    } on VoiceProbeWriterException {
      // Playback failure is non-fatal for the probe and carries no detail.
    }
  }

  Future<void> _failAndTeardown(int attempt, VoiceProbeErrorCode code) {
    if (!_isCurrent(attempt)) {
      return Future<void>.value();
    }
    _cancellation?.cancel();
    return _teardown ??= _terminalClose(VoiceProbePhase.failed, code: code);
  }

  Future<void> _cancelAndTeardown(int attempt) {
    if (!_isCurrent(attempt)) {
      return Future<void>.value();
    }
    return _teardown ??= _terminalClose(VoiceProbePhase.closed);
  }

  Future<void> _terminalClose(
    VoiceProbePhase phase, {
    VoiceProbeErrorCode? code,
  }) async {
    await _cancelResourcesAndClose(phase, code: code);
  }

  /// Discards armed-but-not-finalized writers, tears the WebRTC session down
  /// exactly once, moves to a terminal phase and marks the barrier terminal.
  Future<void> _cancelResourcesAndClose(
    VoiceProbePhase phase, {
    VoiceProbeErrorCode? code,
  }) async {
    await _closeHeldWriters();
    await _releaseWebRtc();
    _active = false;
    _emit(
      VoiceProbeState(phase: phase, errorCode: code, diagnostics: _diagnostics),
    );
    // Terminal reached; the barrier settles once the start/connect body (which
    // may still be pending after a mid-flight cancel) and any arming have left.
    _barrier?.markTerminal();
  }

  /// Closes and forgets both writers (armed-but-unfinalized OR a held ready
  /// result). Each writer's native `close` is idempotent, so this is safe to
  /// call more than once.
  Future<void> _closeHeldWriters() async {
    final user = _userWriter;
    final assistant = _assistantWriter;
    _userWriter = null;
    _assistantWriter = null;
    await user?.close();
    await assistant?.close();
  }

  Future<void> _releaseWebRtc() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _release?.releaseAll();
  }

  void _resetTurnFlags() {
    _sessionUpdateSent = false;
    _arming = false;
    _armed = false;
    _userTurnEnded = false;
    _responseActive = false;
    _responseCancelSent = false;
    _responseCreated = false;
    _outputAudioStarted = false;
    _outputAudioStopped = false;
    _responseDone = false;
    _userDiag = null;
    _assistantDiag = null;
  }

  /// Stops any live session and closes a held ready result's writers exactly
  /// once, then releases the state stream. Idempotent.
  Future<void> dispose() async {
    await stop();
    await _closeHeldWriters();
    if (!_states.isClosed) {
      await _states.close();
    }
  }
}
