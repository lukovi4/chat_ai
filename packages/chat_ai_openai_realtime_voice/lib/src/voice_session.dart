// The speech-to-speech voice session's state machine and money-safe
// coordinator. It owns ONE device → OpenAI Realtime WebRTC lifecycle and
// enforces one-mint / one-signaling-POST / no-retry / no-reconnect /
// exactly-once teardown. It is NOT a ChatBackend and does not use ChatSession.
//
// [state] carries only a coarse [phase] and an optional coarse [failure]. The
// ephemeral secret, SDP, Authorization, system prompt, audio, raw Realtime
// events, response bodies, provider errors, IDs, usage and track ids never
// reach state, logs or exceptions.
//
// The one deliberate exception is the OPTIONAL [transcripts] stream: when the
// app sets `transcriptsEnabled`, the session emits ONLY the final user and
// assistant transcript TEXT (never deltas, ids, usage or a failure), carried
// straight from the same direct device → OpenAI Realtime session. The package
// still never logs or stores that text.
//
// One instance == one WebRTC session:
// - start() is allowed exactly once (a repeat is a programming error);
// - exactly one ClientSecretProvider call and one signaling POST;
// - no retry/reconnect/renewal — the maximum server-side Realtime session
//   length is documented as 60 minutes but no renewal is implemented here;
// - stop()/dispose() are idempotent; late-materialized resources are closed
//   exactly once and start's settlement waits for that close.
//
// The private transport/clock seams live on the private constructor; the only
// public constructor is the approved production one. Tests reach the seams
// through the package-internal top-level [voiceSessionForTesting] (mirrors the
// core's `chatSessionForTesting`); neither the seams nor that helper are ever
// exported from the barrel.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:chat_ai/chat_ai.dart' show BotProfile;
import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart'
    show ClientSecretProvider;
import 'package:flutter/foundation.dart';

import 'voice_cancellation.dart';
import 'voice_recorder.dart';
import 'voice_recording.dart';
import 'voice_recording_coordinator.dart';
import 'voice_session_update.dart';
import 'voice_state.dart';
import 'voice_transcript.dart';
import 'voice_transport.dart';

/// Builds one fresh transport for the single Start (nothing is pooled).
typedef RealtimeVoiceTransportFactory = RealtimeVoiceTransport Function();

/// The one narrow clock seam for the response idle watchdog: a test provides a
/// controllable timer so the money-safe timeout is deterministic. Not a
/// scheduling framework.
typedef VoiceWatchdogTimerFactory =
    Timer Function(Duration duration, void Function() onTimeout);

RealtimeVoiceTransport _defaultTransportFactory() =>
    WebRtcRealtimeVoiceTransport();

Timer _defaultWatchdogTimer(Duration duration, void Function() onTimeout) =>
    Timer(duration, onTimeout);

class OpenAIRealtimeVoiceSession {
  /// The one public constructor. Validation is synchronous — an invalid model/
  /// voice/`maxOutputTokens`/`responseIdleTimeout`, or a non-empty
  /// `botProfile.tools` (tools are not supported by this increment), throws an
  /// [ArgumentError] here, BEFORE any mint or network I/O.
  OpenAIRealtimeVoiceSession({
    required ClientSecretProvider clientSecretProvider,
    required BotProfile botProfile,
    OpenAIRealtimeVoiceMode mode = OpenAIRealtimeVoiceMode.singleTurn,
    String model = 'gpt-realtime-2.1',
    String voice = 'marin',
    int maxOutputTokens = 4096,
    Duration responseIdleTimeout = const Duration(seconds: 60),
    bool transcriptsEnabled = false,
    String inputTranscriptionModel = 'gpt-4o-mini-transcribe',
    bool recordingEnabled = false,
    String? recordingDirectoryPath,
  }) : this._(
         clientSecretProvider: clientSecretProvider,
         botProfile: botProfile,
         mode: mode,
         model: model,
         voice: voice,
         maxOutputTokens: maxOutputTokens,
         responseIdleTimeout: responseIdleTimeout,
         transcriptsEnabled: transcriptsEnabled,
         inputTranscriptionModel: inputTranscriptionModel,
         recordingEnabled: recordingEnabled,
         recordingDirectoryPath: recordingDirectoryPath,
         transportFactory: _defaultTransportFactory,
         timerFactory: _defaultWatchdogTimer,
         // The production recorder factory is built lazily below, only after
         // synchronous validation has accepted an absolute directory path.
         recorderFactory: null,
       );

  OpenAIRealtimeVoiceSession._({
    required ClientSecretProvider clientSecretProvider,
    required BotProfile botProfile,
    required OpenAIRealtimeVoiceMode mode,
    required String model,
    required String voice,
    required int maxOutputTokens,
    required Duration responseIdleTimeout,
    required bool transcriptsEnabled,
    required String inputTranscriptionModel,
    required bool recordingEnabled,
    required String? recordingDirectoryPath,
    required RealtimeVoiceTransportFactory transportFactory,
    required VoiceWatchdogTimerFactory timerFactory,
    required RealtimeVoiceRecorderFactory? recorderFactory,
  }) : _provider = clientSecretProvider,
       _botProfile = botProfile,
       _mode = mode,
       _model = model,
       _voice = voice,
       _maxOutputTokens = maxOutputTokens,
       _responseIdleTimeout = responseIdleTimeout,
       _transcriptsEnabled = transcriptsEnabled,
       _inputTranscriptionModel = inputTranscriptionModel,
       _recordingEnabled = recordingEnabled,
       _recordingDirectoryPath = recordingDirectoryPath,
       _transportFactory = transportFactory,
       _timerFactory = timerFactory {
    _validate();
    if (_recordingEnabled) {
      // A test may inject a Dart-only fake factory; production builds the native
      // (iOS) writer factory bound to the validated directory. PCM never crosses
      // the boundary — see [NativeRealtimeVoiceRecorderFactory].
      final factory =
          recorderFactory ??
          NativeRealtimeVoiceRecorderFactory(
            directoryPath: _recordingDirectoryPath!,
          ).call;
      _recording = VoiceRecordingCoordinator(
        recorderFactory: factory,
        transcriptsEnabled: _transcriptsEnabled,
        transcriptPairingTimeout: _responseIdleTimeout,
        timerFactory: _timerFactory,
        onRecording: _emitRecording,
        onFailure: _emitRecordingFailure,
      );
    }
  }

  final ClientSecretProvider _provider;
  final BotProfile _botProfile;
  final OpenAIRealtimeVoiceMode _mode;
  final String _model;
  final String _voice;
  final int _maxOutputTokens;
  final Duration _responseIdleTimeout;
  final bool _transcriptsEnabled;
  final String _inputTranscriptionModel;
  final bool _recordingEnabled;
  final String? _recordingDirectoryPath;
  final RealtimeVoiceTransportFactory _transportFactory;
  final VoiceWatchdogTimerFactory _timerFactory;

  // The optional recording coordinator. Non-null only when the app opted in AND
  // a recorder factory exists (production always builds one). It owns the two
  // native writers and emits finished files / per-side failures.
  VoiceRecordingCoordinator? _recording;

  final StreamController<OpenAIRealtimeVoiceState> _states =
      StreamController<OpenAIRealtimeVoiceState>.broadcast();
  OpenAIRealtimeVoiceState _state = const OpenAIRealtimeVoiceState.idle();

  // The optional local-recording side channels. In-memory broadcast only; they
  // exist even when recording is off (they simply stay silent) and are closed in
  // dispose() alongside [_states].
  final StreamController<OpenAIRealtimeVoiceRecording> _recordings =
      StreamController<OpenAIRealtimeVoiceRecording>.broadcast();
  final StreamController<OpenAIRealtimeVoiceRecordingFailure>
  _recordingFailures =
      StreamController<OpenAIRealtimeVoiceRecordingFailure>.broadcast();

  // The current OPEN user recording segment (recording-only bookkeeping). The
  // item id and its verified audio_start_ms let a later speech_stopped be
  // validated as a matched VAD pair before the segment is cut.
  String? _recUserItemId;
  int _recUserStartMs = 0;

  // The optional final-transcript side channel. In-memory only, no history; it
  // exists at all only when the app opted in. Closed in dispose() alongside
  // [_states]; a terminal teardown forbids any further transcript event.
  final StreamController<OpenAIRealtimeVoiceTranscript> _transcripts =
      StreamController<OpenAIRealtimeVoiceTranscript>.broadcast();

  // The OPTIONAL assistant transcript-DELTA side channel (only meaningful when
  // transcriptsEnabled). Broadcast, in-memory only, no history: it carries the
  // raw `delta` String of each response.output_audio_transcript.delta of the
  // CURRENT response, verbatim and in order — never an id/index/usage, never the
  // final `.done` (that stays on [_transcripts]). Closed in dispose(). The text
  // is never logged or stored.
  final StreamController<String> _assistantTranscriptDeltas =
      StreamController<String>.broadcast();

  // Lifecycle guards.
  bool _startCalled = false; // start() is allowed exactly once.
  bool _disposed = false; // after dispose(), start() is rejected.
  bool _active = false; // a live session is processing events.
  RealtimeVoiceCancellation? _cancellation;
  RealtimeVoiceTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _eventsSub;
  Future<void>? _teardown; // memoized exactly-once teardown.
  // Completes at the first terminal teardown (any path). The recording
  // remote-track waiter races this so it can NEVER stay pending after a
  // terminate/close/cancel, without triggering the transport's release early.
  final Completer<void> _terminating = Completer<void>();

  bool _sessionUpdateSent = false;
  bool _userTurnClosed = false; // singleTurn: the one user turn has ended.

  // Audio-readiness gate: the mic is enabled only once BOTH a successful
  // session.updated has arrived AND transport.connect() has fully returned
  // (including audio configuration). Ordering between the two is not
  // guaranteed — session.updated can arrive over the DataChannel before
  // connect() returns — so both are latched and the mic is enabled when the
  // second condition is met.
  bool _connectCompleted = false;
  bool _sessionUpdatedAck = false;
  bool _micEnabled = false;

  // Current response tracking (money-safe watchdog + completion). The active
  // response is bound ONLY by the first response.created carrying a non-empty
  // response.id; completion/progress events count only on an exact id match.
  String? _activeResponseId;
  bool _responseActive = false;
  bool _responseDone = false; // set true ONLY on a `completed` response.done.
  bool _outputAudioStopped = false;
  bool _responseCancelSent = false;
  Timer? _watchdog;
  // Memoized programmatic-interrupt operation for the CURRENT response. Set on
  // the first interruptResponse() for a response so concurrent/repeat calls
  // share one result (exactly one cancel/clear/finalize); reset to null when the
  // next response.created binds a fresh response.
  Future<void>? _interrupt;
  // A monotonic counter for INTERNAL client-event ids on programmatic
  // cancel/clear. The ids are opaque (`pcx_<n>` / `pcl_<n>`), never exported,
  // logged, or placed in state/exceptions, and carry no user data.
  int _clientEventSeq = 0;
  // The internal event ids of programmatic `response.cancel`s whose correlated
  // server `error` is RECOVERABLE (the server had nothing to cancel). Minimal
  // correlation only; kept until terminal teardown (NOT cleared when the next
  // response binds — a safe late error for a previous response's cancel can
  // arrive after a newer response and must stay inert). The clear event id is
  // deliberately NOT tracked here (a clear error stays terminal).
  final Set<String> _recoverableCancelEventIds = <String>{};
  // Increments on every processed user speech_started and every newly-bound
  // response, so a still-in-flight programmatic interrupt can tell whether a
  // NEWER turn/response arose since it began (and thus must not overwrite the
  // newer state with `listening`).
  int _turnEpoch = 0;

  String _nextClientEventId(String prefix) => '${prefix}_${_clientEventSeq++}';

  // ---- Optional transcript attribution (only when _transcriptsEnabled) -----
  // Minimal in-memory bookkeeping so a final transcript can be attributed to a
  // reply/response THIS session already saw, and never emitted twice. No IDs
  // ever leave the package.
  //
  // User item ids seen via a valid input_audio_buffer.speech_stopped.
  final Set<String> _knownUserItemIds = <String>{};
  // User item ids whose transcription reached a terminal outcome
  // (completed OR failed) — guards duplicate/terminal re-emission.
  final Set<String> _resolvedUserItemIds = <String>{};
  // Response ids seen via a valid response.created (kept even after a barge-in
  // abandons the active response, so the spoken part's transcript may still
  // emit — see §3.3).
  final Set<String> _knownResponseIds = <String>{};
  // Identity keys of assistant transcripts already emitted (duplicate guard).
  final Set<String> _emittedAssistantKeys = <String>{};
  // singleTurn only: the first allowed user reply's item id, and whether its
  // async transcription terminal outcome (completed/failed) — or the idle
  // timeout upper bound — has been reached. singleTurn will not close the
  // transport until this is resolved.
  String? _pendingUserItemId;
  bool _userTranscriptResolved = false;

  void _validate() {
    if (_model.trim().isEmpty) {
      throw ArgumentError.value(_model, 'model', 'must not be empty');
    }
    if (_voice.trim().isEmpty) {
      throw ArgumentError.value(_voice, 'voice', 'must not be empty');
    }
    if (_maxOutputTokens < 1 || _maxOutputTokens > 4096) {
      throw ArgumentError.value(
        _maxOutputTokens,
        'maxOutputTokens',
        'must be in 1..4096',
      );
    }
    if (_responseIdleTimeout <= Duration.zero) {
      throw ArgumentError.value(
        _responseIdleTimeout,
        'responseIdleTimeout',
        'must be greater than Duration.zero',
      );
    }
    if (_botProfile.tools.isNotEmpty) {
      // Tools are a later increment; fail loudly rather than silently dropping
      // them — BEFORE any mint/network.
      throw ArgumentError.value(
        _botProfile.tools.length,
        'botProfile.tools',
        'tools are not supported by this increment; construct without tools',
      );
    }
    if (_transcriptsEnabled && _inputTranscriptionModel.trim().isEmpty) {
      // An empty transcription model is rejected synchronously, BEFORE any
      // mint/network — never sent to the provider.
      throw ArgumentError.value(
        _inputTranscriptionModel,
        'inputTranscriptionModel',
        'must not be empty when transcriptsEnabled is true',
      );
    }
    if (_recordingEnabled) {
      // A missing / empty / non-absolute directory is rejected synchronously,
      // BEFORE any mint/network. When recording is off the path is ignored.
      //
      // The exception is SANITIZED: it names only the parameter and the rule,
      // never the offending path value — a directory path can itself be
      // sensitive, so it must never appear in an exception's toString or a log.
      final path = _recordingDirectoryPath;
      if (path == null || path.trim().isEmpty || !path.startsWith('/')) {
        throw ArgumentError(
          'recordingDirectoryPath must be a non-empty absolute path when '
          'recordingEnabled is true',
        );
      }
    }
  }

  OpenAIRealtimeVoiceState get state => _state;
  Stream<OpenAIRealtimeVoiceState> get states => _states.stream;

  /// A broadcast stream of the OPTIONAL final transcripts, in the order the
  /// live session delivered them. Emits nothing unless `transcriptsEnabled` was
  /// set at construction. It carries only successfully-received FINAL text —
  /// user and assistant — and never deltas, ids, usage or a failure. Closed by
  /// [dispose].
  Stream<OpenAIRealtimeVoiceTranscript> get transcripts => _transcripts.stream;

  /// A broadcast stream of the assistant transcript DELTAS of the current
  /// response, in arrival order. Each event is the raw `delta` String of a
  /// `response.output_audio_transcript.delta`, passed through EXACTLY as
  /// received — never trimmed, normalized, merged, deduplicated or accumulated
  /// (two identical adjacent fragments are BOTH emitted). The application
  /// assembles any displayed text itself.
  ///
  /// It emits nothing unless `transcriptsEnabled` was set at construction, and
  /// never carries an id, index, usage or the final `.done` (which stays on
  /// [transcripts]). It shares the SAME `transcriptsEnabled` opt-in — there is no
  /// separate option. Closed by [dispose].
  Stream<String> get assistantTranscriptDeltas =>
      _assistantTranscriptDeltas.stream;

  /// A broadcast stream of finished per-reply recordings, in the order they were
  /// finalized. Emits nothing unless `recordingEnabled` was set at construction.
  /// Each event carries the app-owned `.m4a` path, the optional paired transcript
  /// and the [OpenAIRealtimeVoiceRecording.interrupted] flag. Closed by
  /// [dispose].
  Stream<OpenAIRealtimeVoiceRecording> get recordings => _recordings.stream;

  /// A broadcast stream of coarse per-side recording failures. It is a SIDE
  /// CHANNEL: a recording failure never becomes an [OpenAIRealtimeVoiceState]
  /// failure, never ends the session and never triggers a retry/reconnect/mint.
  /// Closed by [dispose].
  Stream<OpenAIRealtimeVoiceRecordingFailure> get recordingFailures =>
      _recordingFailures.stream;

  void _emitRecording(OpenAIRealtimeVoiceRecording recording) {
    if (!_recordings.isClosed) {
      _recordings.add(recording);
    }
  }

  void _emitRecordingFailure(OpenAIRealtimeVoiceRecordingFailure failure) {
    if (!_recordingFailures.isClosed) {
      _recordingFailures.add(failure);
    }
  }

  void _emit(OpenAIRealtimeVoiceState next) {
    _state = next;
    if (!_states.isClosed) {
      _states.add(next);
    }
  }

  void _setPhase(OpenAIRealtimeVoicePhase phase) =>
      _emit(OpenAIRealtimeVoiceState(phase: phase));

  bool _isCancelled() => _cancellation?.isCancelled ?? false;

  /// The one manual Start. Rejected synchronously (before any await, so no
  /// mint/connect/signaling) if the session was disposed, or if start() was
  /// already called (one instance == one WebRTC session).
  Future<void> start() async {
    if (_disposed) {
      throw StateError(
        'OpenAIRealtimeVoiceSession.start() cannot be called after dispose(); '
        'create a new instance for another session',
      );
    }
    if (_startCalled) {
      throw StateError(
        'OpenAIRealtimeVoiceSession.start() may be called only once; '
        'create a new instance for another session',
      );
    }
    _startCalled = true;
    _active = true;
    final cancellation = RealtimeVoiceCancellation();
    _cancellation = cancellation;

    _setPhase(OpenAIRealtimeVoicePhase.minting);
    try {
      // Exactly one client-secret mint.
      final secret = await _provider.getClientSecret(botId: _botProfile.id);
      if (_isCancelled()) {
        throw const RealtimeVoiceConnectCancelled();
      }

      _setPhase(OpenAIRealtimeVoicePhase.connecting);
      final transport = _transportFactory();
      _transport = transport;

      // Subscribe BEFORE connect can accept the first DataChannel message, so
      // an early session.created (delivered during connect) is never dropped.
      _eventsSub = transport.events.listen(
        (event) => unawaited(_onEvent(event)),
        onDone: _onEventsDone,
        onError: (_) {},
      );

      // Exactly one signaling attempt; never retried.
      await transport.connect(secret, cancellation);
      if (_isCancelled()) {
        throw const RealtimeVoiceConnectCancelled();
      }

      // connect() (including audio configuration) has fully returned. The mic
      // may now go live if a session.updated has already been acknowledged.
      _connectCompleted = true;
      _maybeEnableMic();
    } on RealtimeVoiceMicException {
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.microphone,
        cancelActiveResponse: false,
      );
    } on RealtimeVoiceConnectCancelled {
      await _cancelAndClose();
    } on RealtimeVoiceConnectException {
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.connect,
        cancelActiveResponse: false,
      );
    } catch (_) {
      // The provider's own sanitized exception surfaces here; classified by
      // phase with no detail retained.
      if (_state.phase == OpenAIRealtimeVoicePhase.minting) {
        await _failAndTeardown(
          OpenAIRealtimeVoiceFailure.mint,
          cancelActiveResponse: false,
        );
      } else {
        await _failAndTeardown(
          OpenAIRealtimeVoiceFailure.connect,
          cancelActiveResponse: false,
        );
      }
    }
  }

  Future<void> _onEvent(Map<String, Object?> event) async {
    if (!_active) {
      return;
    }
    final type = event['type'];
    if (type is! String) {
      return;
    }
    // Idle watchdog: only a KNOWN, structurally-minimal progress event of the
    // current, still-active response resets it (never a foreign, unknown or
    // malformed look-alike).
    _maybeKickWatchdog(type, event);
    switch (type) {
      case 'session.created':
        await _sendSessionUpdateOnce();
      case 'session.updated':
        _onSessionUpdated();
      case 'input_audio_buffer.speech_started':
        _onSpeechStarted(event);
      case 'input_audio_buffer.speech_stopped':
        _onSpeechStopped(event);
      case 'response.created':
        _onResponseCreated(event);
      case 'output_audio_buffer.started':
        _onOutputAudioStarted(event);
      case 'output_audio_buffer.stopped':
        _onOutputAudioStopped(event);
      case 'response.done':
        _onResponseDone(event);
      case 'conversation.item.input_audio_transcription.completed':
        _onUserTranscriptCompleted(event);
      case 'conversation.item.input_audio_transcription.failed':
        _onUserTranscriptFailed(event);
      case 'response.output_audio_transcript.delta':
        _onAssistantTranscriptDelta(event);
      case 'response.output_audio_transcript.done':
        _onAssistantTranscriptDone(event);
      case 'error':
        await _onErrorEvent(event);
    }
  }

  Future<void> _sendSessionUpdateOnce() async {
    if (!_active || _sessionUpdateSent) {
      return;
    }
    _sessionUpdateSent = true;
    final transport = _transport;
    if (transport == null) {
      return;
    }
    try {
      // Exactly one session.update; server semantic VAD creates the responses.
      await transport.send(
        buildRealtimeVoiceSessionUpdate(
          model: _model,
          voice: _voice,
          instructions: _botProfile.systemPrompt,
          maxOutputTokens: _maxOutputTokens,
          transcriptsEnabled: _transcriptsEnabled,
          inputTranscriptionModel: _inputTranscriptionModel,
        ),
      );
    } catch (_) {
      // Failing to configure the session before the mic goes live is a setup
      // failure — no retry.
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.session,
        cancelActiveResponse: false,
      );
    }
  }

  void _onSessionUpdated() {
    if (!_active) {
      return;
    }
    // Latch only the acknowledgement; the mic is armed by [_maybeEnableMic]
    // once connect() has also fully returned (audio-readiness race).
    _sessionUpdatedAck = true;
    _maybeEnableMic();
  }

  /// Enables the one microphone track exactly once, and ONLY when both a
  /// successful session.updated has been acknowledged AND transport.connect()
  /// (including audio configuration) has fully returned.
  ///
  /// When recording is enabled the USER tap is attached to the EXISTING local
  /// track BEFORE the microphone goes live (so the onset of the reply is never
  /// clipped); the mic is then enabled and the ASSISTANT tap is attached in the
  /// background once the remote track id is available.
  void _maybeEnableMic() {
    if (!_active || _micEnabled || !_connectCompleted || !_sessionUpdatedAck) {
      return;
    }
    _micEnabled = true; // latched here so this runs exactly once
    final recording = _recording;
    if (recording == null) {
      _transport?.setMicrophoneEnabled(true);
      _setPhase(OpenAIRealtimeVoicePhase.listening);
      return;
    }
    unawaited(_armRecordersThenEnableMic(recording));
  }

  Future<void> _armRecordersThenEnableMic(
    VoiceRecordingCoordinator recording,
  ) async {
    final transport = _transport;
    if (transport == null) {
      return;
    }
    // Attach the USER tap first — before the mic is enabled — so the very start
    // of the user's reply is captured. A recorder failure here is a side-channel
    // failure only and never blocks the mic or the voice session.
    final localId = transport.localAudioTrackId;
    if (localId != null && localId.isNotEmpty) {
      try {
        await recording.attachUser(localId);
      } catch (_) {}
    }
    if (!_active) {
      return; // a teardown raced the async arming
    }
    transport.setMicrophoneEnabled(true);
    _setPhase(OpenAIRealtimeVoicePhase.listening);
    unawaited(_attachAssistantRecorder(recording, transport));
  }

  /// Attaches the assistant tap once the remote track id is available. The wait
  /// is raced against BOTH the setup cancellation and the terminal-teardown
  /// signal, so it can never stay pending after a terminate/close/cancel — even
  /// when the remote track never arrives (a session that closes before the
  /// assistant ever speaks). A late arrival after teardown is ignored.
  Future<void> _attachAssistantRecorder(
    VoiceRecordingCoordinator recording,
    RealtimeVoiceTransport transport,
  ) async {
    final cancellation = _cancellation;
    String? remoteId;
    try {
      remoteId = await Future.any<String?>(<Future<String?>>[
        transport.remoteAudioTrackId,
        _terminating.future.then((_) => null),
        if (cancellation != null) cancellation.whenCancelled.then((_) => null),
      ]);
    } catch (_) {
      return;
    }
    if (remoteId == null || remoteId.isEmpty || !_active) {
      // The session closed before the assistant reply began, or the track never
      // arrived: no attach, no false failure for a role that never spoke.
      return;
    }
    try {
      await recording.attachAssistant(remoteId);
    } catch (_) {}
  }

  void _onSpeechStarted(Map<String, Object?> event) {
    if (!_active || !_micEnabled) {
      return;
    }
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn && _userTurnClosed) {
      // singleTurn accepts exactly one user turn; the mic is already off.
      return;
    }
    // A new user turn begins — a newer state than any in-flight interrupt.
    _turnEpoch++;
    if (_responseActive) {
      // Barge-in: the server (interrupt_response: true) cancels the response
      // and truncates unplayed audio itself. We send NO redundant
      // response.cancel/truncate — only reflect the state and stop the
      // watchdog for the abandoned response. The assistant's actually-played
      // fragment is finalized as an interrupted recording.
      final responseId = _activeResponseId;
      if (responseId != null) {
        _recording?.interruptAssistantSegment(responseId);
      }
      _abandonActiveResponse();
    }
    _beginUserRecordingSegment(event);
    _setPhase(OpenAIRealtimeVoicePhase.userSpeaking);
  }

  /// Opens a user recording segment on a verified speech_started boundary: a
  /// non-empty item id and a non-negative integer `audio_start_ms`. The
  /// continuously-attached tap (armed before the mic) preserves the onset.
  ///
  /// Boundaries are EVENT-DRIVEN: the segment spans the arrival of a valid
  /// speech_started → speech_stopped pair. `audio_start_ms` / `audio_end_ms` are
  /// used ONLY for validation, item_id matching and dedup — never as sample-
  /// accurate PCM offsets (see the package docs: no OpenAI↔PCM timeline mapping
  /// exists over flutter_webrtc, so no sample-accurate boundary is claimed).
  ///
  /// Only ONE user segment is active at a time. While one is open, any further
  /// speech_started (a duplicate, an overlapping start, or an out-of-order
  /// event) is IGNORED: it never closes, replaces or destroys the active
  /// segment's in-progress file.
  void _beginUserRecordingSegment(Map<String, Object?> event) {
    final recording = _recording;
    if (recording == null) {
      return;
    }
    if (_recUserItemId != null) {
      // A user segment is already open — never overwrite it. A repeat/overlap/
      // out-of-order speech_started is dropped here.
      return;
    }
    final itemId = _asNonEmptyString(event['item_id']);
    final startMs = event['audio_start_ms'];
    if (itemId == null || !_isNonNegativeInt(startMs)) {
      return;
    }
    _recUserItemId = itemId;
    _recUserStartMs = startMs! as int;
    recording.beginUserSegment(itemId);
  }

  void _onSpeechStopped(Map<String, Object?> event) {
    if (!_active || !_micEnabled) {
      return;
    }
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn) {
      if (_userTurnClosed) {
        return;
      }
      // Disable the mic on the FIRST speech_stopped so no second user turn can
      // ever open within this singleTurn session.
      _userTurnClosed = true;
      _transport?.setMicrophoneEnabled(false);
    }
    _trackUserItem(event);
    _endUserRecordingSegment(event);
    // The assistant's response follows (server VAD create_response).
    _setPhase(OpenAIRealtimeVoicePhase.assistantSpeaking);
  }

  /// Closes the open user recording segment on a verified speech_stopped
  /// boundary: the SAME non-empty item id, a non-negative integer audio_end_ms,
  /// and audio_end_ms >= the segment's audio_start_ms. A malformed / foreign /
  /// duplicate stop does not cut the segment (it is left open; a valid stop, or
  /// teardown as an interrupted fragment, closes it) and never fabricates a file.
  void _endUserRecordingSegment(Map<String, Object?> event) {
    final recording = _recording;
    final openItemId = _recUserItemId;
    if (recording == null || openItemId == null) {
      return;
    }
    final itemId = _asNonEmptyString(event['item_id']);
    final endMs = event['audio_end_ms'];
    if (itemId != openItemId ||
        !_isNonNegativeInt(endMs) ||
        (endMs! as int) < _recUserStartMs) {
      return;
    }
    _recUserItemId = null;
    _recUserStartMs = 0;
    recording.endUserSegment(openItemId);
  }

  /// Remembers the user reply's item id so a later
  /// input_audio_transcription.completed/.failed can be attributed to a reply
  /// THIS session actually saw. No-op unless transcripts are enabled. In
  /// singleTurn it also latches the first reply as the one whose transcription
  /// terminal outcome the auto-close waits for.
  void _trackUserItem(Map<String, Object?> event) {
    if (!_transcriptsEnabled) {
      return;
    }
    final itemId = _asNonEmptyString(event['item_id']);
    if (itemId == null) {
      return;
    }
    _knownUserItemIds.add(itemId);
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn &&
        _pendingUserItemId == null) {
      _pendingUserItemId = itemId;
    }
  }

  void _onResponseCreated(Map<String, Object?> event) {
    if (!_active) {
      return;
    }
    if (_activeResponseId != null) {
      // A repeat response.created never rebinds the active response, resets its
      // flags or kicks the watchdog.
      return;
    }
    final id = _nestedResponseId(event);
    if (id == null) {
      // An id-less / structurally invalid response.created during a live
      // session cannot bind an active response — one terminal transport
      // failure, no retry.
      unawaited(
        _failAndTeardown(
          OpenAIRealtimeVoiceFailure.transport,
          cancelActiveResponse: false,
        ),
      );
      return;
    }
    // A fresh response begins: reset per-response flags and arm the watchdog.
    _activeResponseId = id;
    // Remembered even beyond a later barge-in, so the spoken part's assistant
    // transcript may still be attributed and emitted (§3.3). IDs never leave
    // the package.
    _knownResponseIds.add(id);
    _responseActive = true;
    _responseDone = false;
    _outputAudioStopped = false;
    _responseCancelSent = false;
    // A fresh response is interruptible again: drop any memoized interrupt of a
    // previous response and mark a newer state than any in-flight interrupt.
    // The programmatic-cancel recoverable-error correlation is deliberately NOT
    // cleared here: a SAFE late server `error` for the PREVIOUS response's
    // cancel can arrive after this new response was created and must stay inert
    // (it must never terminate the new, live response). Those ids are unique per
    // cancel and only ever match their own server error, so keeping them until
    // terminal teardown is safe.
    _interrupt = null;
    _turnEpoch++;
    _setPhase(OpenAIRealtimeVoicePhase.assistantSpeaking);
    _kickWatchdog();
  }

  void _onOutputAudioStarted(Map<String, Object?> event) {
    if (!_active || !_matchesActiveResponse(_topResponseId(event))) {
      return;
    }
    _responseActive = true;
    // Begin the assistant recording segment at the actual start of output audio
    // of THIS response (the continuously-attached remote tap preserves the
    // onset). A duplicate started is ignored by the coordinator.
    final responseId = _activeResponseId;
    if (responseId != null) {
      _recording?.beginAssistantSegment(responseId);
    }
    _setPhase(OpenAIRealtimeVoicePhase.assistantSpeaking);
  }

  void _onOutputAudioStopped(Map<String, Object?> event) {
    // Accepted only with an exact response_id match of the active response.
    if (!_active || !_matchesActiveResponse(_topResponseId(event))) {
      return;
    }
    if (_outputAudioStopped) {
      // A duplicate output_audio_buffer.stopped for the SAME response never
      // re-finalizes the recording, re-arms the idle deadline or re-evaluates.
      return;
    }
    _outputAudioStopped = true;
    _responseActive = false;
    // A naturally completed assistant reply: close its segment (not interrupted)
    // while the active response id is still bound.
    final responseId = _activeResponseId;
    if (responseId != null) {
      _recording?.endAssistantSegment(responseId);
    }
    if (_responseDone) {
      // Both conditions met — the normal completion path (which disarms the
      // watchdog) closes the turn.
      _disarmWatchdog();
      _evaluateResponseCompletion();
    } else {
      // The audio stopped but the matching response.done has NOT arrived yet.
      // Re-arm the EXISTING watchdog for a fresh idle period so a LOST
      // response.done can never hang the turn: a completed response.done that
      // arrives first cancels this deadline and completes the turn normally;
      // otherwise the deadline ends the session with exactly one
      // responseTimeout. Reuses the existing timer seam — no new timeout/option.
      _kickWatchdog();
    }
  }

  void _onResponseDone(Map<String, Object?> event) {
    // response.done must carry a response.id matching the active response; a
    // missing id, no active response, or a foreign/abandoned response (e.g. a
    // late done after a barge-in) is inert.
    if (!_active || !_matchesActiveResponse(_nestedResponseId(event))) {
      return;
    }
    final response = event['response'];
    final status = response is Map ? response['status'] : null;
    if (status == 'completed') {
      // Only a `completed` response.done is a successful completion.
      _responseDone = true;
      _evaluateResponseCompletion();
      return;
    }
    // cancelled / failed / incomplete / missing / unknown status of the active
    // response → one terminal transport failure, teardown, no retry/reconnect.
    unawaited(
      _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      ),
    );
  }

  /// singleTurn closes only after BOTH a `completed` response.done AND the
  /// matching output_audio_buffer.stopped (never on response.done alone);
  /// conversation returns to listening and accepts the next VAD turn.
  ///
  /// With transcripts enabled the async user transcription is a THIRD singleTurn
  /// close condition: the auto-close waits for the first reply's transcription
  /// terminal outcome (completed/failed), bounded above by the existing idle
  /// timeout seam so a lost/malformed transcript can never hang the turn.
  void _evaluateResponseCompletion() {
    if (!(_responseDone && _outputAudioStopped)) {
      return;
    }
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn &&
        _awaitingUserTranscript()) {
      // Audio response finished, but the async user transcript is still
      // pending. Do NOT close the transport yet; reuse the idle-timeout seam as
      // the upper bound instead of adding a new timeout/timer.
      _armUserTranscriptDeadline();
      return;
    }
    _disarmWatchdog();
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn) {
      // Controlled, successful auto-close of the one turn.
      unawaited(
        _teardown ??= _terminate(
          OpenAIRealtimeVoicePhase.ended,
          failure: null,
          cancelActiveResponse: false,
        ),
      );
    } else {
      // conversation: keep the connection, ready for the next turn. A pending
      // user transcript never blocks the next VAD turn or Response.
      _resetResponseState();
      _setPhase(OpenAIRealtimeVoicePhase.listening);
    }
  }

  /// True while singleTurn still owes a terminal outcome for the first reply's
  /// transcription. Never true unless transcripts are enabled and a first user
  /// item was actually observed (so a missing item id can't hang the turn).
  bool _awaitingUserTranscript() =>
      _transcriptsEnabled &&
      _mode == OpenAIRealtimeVoiceMode.singleTurn &&
      _pendingUserItemId != null &&
      !_userTranscriptResolved;

  /// Reuses the single watchdog/timer seam as the upper bound for the pending
  /// user transcript wait. On expiry singleTurn ends normally WITHOUT a
  /// transcript — no retry, reconnect, mint or new Response.
  void _armUserTranscriptDeadline() {
    _watchdog?.cancel();
    _watchdog = _timerFactory(_responseIdleTimeout, _onUserTranscriptDeadline);
  }

  void _onUserTranscriptDeadline() {
    if (!_active) {
      return;
    }
    _userTranscriptResolved = true;
    _disarmWatchdog();
    _maybeFinishSingleTurn();
  }

  /// Marks the singleTurn user-transcript wait satisfied for [itemId] and, if
  /// the audio response has already finished, closes the one turn.
  void _resolveUserTranscriptWait(String itemId) {
    if (_mode != OpenAIRealtimeVoiceMode.singleTurn ||
        itemId != _pendingUserItemId ||
        _userTranscriptResolved) {
      return;
    }
    _userTranscriptResolved = true;
    _maybeFinishSingleTurn();
  }

  /// The controlled singleTurn auto-close, gated on all three conditions:
  /// a completed response.done, the matching output_audio_buffer.stopped and
  /// the user transcription terminal outcome (or its timeout bound).
  void _maybeFinishSingleTurn() {
    if (!(_responseDone && _outputAudioStopped) || _teardown != null) {
      return;
    }
    _disarmWatchdog();
    unawaited(
      _teardown ??= _terminate(
        OpenAIRealtimeVoicePhase.ended,
        failure: null,
        cancelActiveResponse: false,
      ),
    );
  }

  // ---- Optional final transcripts ----------------------------------------

  /// A valid final USER transcript. Emitted only for an item id THIS session
  /// saw via speech_stopped, with a non-negative content_index and a String
  /// transcript (empty allowed), passed through untrimmed. A duplicate/terminal
  /// re-arrival is ignored. Also resolves the singleTurn wait.
  void _onUserTranscriptCompleted(Map<String, Object?> event) {
    if (!_active || !_transcriptsEnabled) {
      return;
    }
    final itemId = _asNonEmptyString(event['item_id']);
    if (itemId == null ||
        !_knownUserItemIds.contains(itemId) ||
        !_isNonNegativeInt(event['content_index'])) {
      return;
    }
    final transcript = event['transcript'];
    if (transcript is! String) {
      return;
    }
    if (!_resolvedUserItemIds.add(itemId)) {
      // Already terminal for this reply — never emit twice.
      return;
    }
    _emitTranscript(OpenAIRealtimeVoiceTranscriptRole.user, transcript);
    // Pair the file with THIS reply's transcript (empty stays an empty string).
    _recording?.resolveUserTranscript(itemId, text: transcript);
    _resolveUserTranscriptWait(itemId);
  }

  /// A user transcription FAILURE for a known reply. A terminal outcome of the
  /// optional side channel only: emit no transcript, keep the voice session
  /// running, cancel nothing, retry nothing, and read/store nothing from the
  /// raw error. Resolves the singleTurn wait like a completed one.
  ///
  /// A malformed `.failed` (missing/negative/non-int content_index, or a
  /// missing/non-Map error) is NOT a terminal outcome — it is ignored entirely,
  /// so a later valid completed is never suppressed. The error's contents are
  /// only shape-checked (`is Map`), never read, validated deeper or stored.
  void _onUserTranscriptFailed(Map<String, Object?> event) {
    if (!_active || !_transcriptsEnabled) {
      return;
    }
    final itemId = _asNonEmptyString(event['item_id']);
    if (itemId == null ||
        !_knownUserItemIds.contains(itemId) ||
        !_isNonNegativeInt(event['content_index']) ||
        event['error'] is! Map) {
      return;
    }
    if (!_resolvedUserItemIds.add(itemId)) {
      return;
    }
    // A transcription failure pairs the file with a null transcript.
    _recording?.resolveUserTranscript(itemId, text: null);
    _resolveUserTranscriptWait(itemId);
  }

  /// A valid assistant transcript DELTA of the CURRENT response. Strict
  /// attribution: the session is active, transcripts are enabled, a current
  /// active response is already bound and the event's non-empty `response_id`
  /// matches it EXACTLY, `item_id` is a non-empty String, `output_index` and
  /// `content_index` are non-negative ints and `delta` is a String. A malformed,
  /// foreign, before-response.created, or post-interrupt/barge-in/terminal/
  /// dispose delta is ignored (post-abandon there is no active id to match). The
  /// raw `delta` is emitted verbatim; nothing else (id/index/usage) leaves the
  /// package and the content is never logged.
  void _onAssistantTranscriptDelta(Map<String, Object?> event) {
    if (!_active || !_transcriptsEnabled) {
      return;
    }
    final responseId = _asNonEmptyString(event['response_id']);
    if (responseId == null || !_matchesActiveResponse(responseId)) {
      return;
    }
    final itemId = _asNonEmptyString(event['item_id']);
    if (itemId == null ||
        !_isNonNegativeInt(event['output_index']) ||
        !_isNonNegativeInt(event['content_index'])) {
      return;
    }
    final delta = event['delta'];
    if (delta is! String) {
      return;
    }
    if (!_assistantTranscriptDeltas.isClosed) {
      _assistantTranscriptDeltas.add(delta);
    }
  }

  /// A valid final ASSISTANT transcript. Emitted for any response id THIS
  /// session saw via response.created — including one later abandoned by a
  /// barge-in (§3.3) — with a non-empty item id, non-negative indices and a
  /// String transcript (empty allowed), passed through untrimmed. A duplicate
  /// (same response/item/indices) is ignored.
  void _onAssistantTranscriptDone(Map<String, Object?> event) {
    if (!_active || !_transcriptsEnabled) {
      return;
    }
    final responseId = _asNonEmptyString(event['response_id']);
    if (responseId == null || !_knownResponseIds.contains(responseId)) {
      return;
    }
    final itemId = _asNonEmptyString(event['item_id']);
    if (itemId == null ||
        !_isNonNegativeInt(event['output_index']) ||
        !_isNonNegativeInt(event['content_index'])) {
      return;
    }
    final transcript = event['transcript'];
    if (transcript is! String) {
      return;
    }
    final key =
        '$responseId|$itemId|${event['output_index']}|${event['content_index']}';
    if (!_emittedAssistantKeys.add(key)) {
      // The exact same terminal transcript event — never emit twice.
      return;
    }
    _emitTranscript(OpenAIRealtimeVoiceTranscriptRole.assistant, transcript);
    // Pair the assistant file with THIS response's transcript.
    _recording?.resolveAssistantTranscript(responseId, text: transcript);
  }

  /// The one transcript sink. A terminal teardown closes the controller, so a
  /// late native/data-channel event after teardown can never emit. The text is
  /// never logged or stored here.
  void _emitTranscript(OpenAIRealtimeVoiceTranscriptRole role, String text) {
    if (_transcripts.isClosed) {
      return;
    }
    _transcripts.add(OpenAIRealtimeVoiceTranscript(role: role, text: text));
  }

  Future<void> _onErrorEvent(Map<String, Object?> event) async {
    if (!_active) {
      return;
    }
    // A RECOVERABLE programmatic-cancel error: when interruptResponse() cancels a
    // response the server may already have finished generating, the server
    // returns an `error` but the session stays usable. Correlate ONLY by the
    // structurally-required nested `error.event_id` against the ids of the
    // programmatic `response.cancel`(s) we sent; nothing else (message/code/
    // param) is read, stored or logged. A correlated cancel error is inert (the
    // current — possibly newer — state is left unchanged). A `clear` error, a
    // foreign/malformed/unrelated error and any error with no matching id stay
    // terminal by the existing contract.
    final error = event['error'];
    if (error is Map) {
      final eventId = error['event_id'];
      if (eventId is String && _recoverableCancelEventIds.contains(eventId)) {
        return;
      }
    }
    // Nothing from the raw event (message/code/param/event_id) is stored. A
    // setup-phase error is a session failure; a live-session error is a
    // transport loss (money-safe once a paid response may have begun).
    final setup = _isSetupPhase();
    await _failAndTeardown(
      setup
          ? OpenAIRealtimeVoiceFailure.session
          : OpenAIRealtimeVoiceFailure.transport,
      cancelActiveResponse: _responseActive,
    );
  }

  void _onEventsDone() {
    // The session died (EOF). No reconnect, no retry.
    if (!_active) {
      return;
    }
    final setup = _isSetupPhase();
    unawaited(
      _failAndTeardown(
        setup
            ? OpenAIRealtimeVoiceFailure.session
            : OpenAIRealtimeVoiceFailure.transport,
        // The channel is already dead — a cancel/clear cannot be sent.
        cancelActiveResponse: false,
      ),
    );
  }

  bool _isSetupPhase() =>
      _state.phase == OpenAIRealtimeVoicePhase.minting ||
      _state.phase == OpenAIRealtimeVoicePhase.connecting;

  /// True only for a non-empty [id] that exactly matches the currently-bound
  /// active response. A missing id is never a match, and there is no match
  /// while no response is active (e.g. after a barge-in abandoned it).
  bool _matchesActiveResponse(String? id) =>
      id != null && _activeResponseId != null && id == _activeResponseId;

  void _abandonActiveResponse() {
    _responseActive = false;
    _resetResponseState();
  }

  void _resetResponseState() {
    _activeResponseId = null;
    _responseActive = false;
    _responseDone = false;
    _outputAudioStopped = false;
    _responseCancelSent = false;
    _disarmWatchdog();
  }

  // ---- Response idle watchdog (money-safe) -------------------------------

  /// The idle watchdog is reset ONLY by a known response/audio PROGRESS event
  /// of the current response with a minimally-correct, type-specific shape.
  /// General gates: an active non-empty response id must already be known, and
  /// the event's `response_id` must be a String that exactly matches it. Then a
  /// per-type structure gate ([_isResponseProgress]). Lifecycle events
  /// (created/done), input/session events, rate-limit events and any
  /// unknown/malformed look-alike never reset it. This is strict attribution,
  /// not a JSON Schema parser (no `event_id`/exhaustive validation), and reuses
  /// no text-adapter code — only the same attribution principle.
  void _maybeKickWatchdog(String type, Map<String, Object?> event) {
    if (!_responseActive || _activeResponseId == null) {
      return;
    }
    if (!_matchesActiveResponse(_topResponseId(event))) {
      return;
    }
    if (!_isResponseProgress(type, event)) {
      return;
    }
    _kickWatchdog();
  }

  /// The per-type minimal-structure gate. Called only after the id gate; an
  /// unknown [type] is never progress.
  static bool _isResponseProgress(String type, Map<String, Object?> event) {
    switch (type) {
      case 'response.output_audio.delta':
      case 'response.output_audio_transcript.delta':
        // Non-empty item_id, non-negative indices, non-empty delta.
        return _hasItemAndIndices(event) && _isNonEmptyString(event['delta']);
      case 'response.output_audio.done':
        // Non-empty item_id, non-negative indices.
        return _hasItemAndIndices(event);
      case 'response.output_audio_transcript.done':
        // Same item_id/indices plus a transcript String.
        return _hasItemAndIndices(event) && event['transcript'] is String;
      case 'response.content_part.added':
      case 'response.content_part.done':
        // Non-empty item_id, non-negative indices, part is a Map.
        return _hasItemAndIndices(event) && event['part'] is Map;
      case 'response.output_item.added':
      case 'response.output_item.done':
        // Non-negative output_index, item is a Map with a non-empty type.
        return _isNonNegativeInt(event['output_index']) &&
            _isItemWithType(event['item']);
      case 'output_audio_buffer.started':
        // The exact current response_id (already gated) is sufficient.
        return true;
      default:
        return false;
    }
  }

  static bool _hasItemAndIndices(Map<String, Object?> event) =>
      _isNonEmptyString(event['item_id']) &&
      _isNonNegativeInt(event['output_index']) &&
      _isNonNegativeInt(event['content_index']);

  static bool _isItemWithType(Object? item) =>
      item is Map && _isNonEmptyString(item['type']);

  static bool _isNonEmptyString(Object? value) =>
      value is String && value.isNotEmpty;

  static bool _isNonNegativeInt(Object? value) => value is int && value >= 0;

  void _kickWatchdog() {
    _watchdog?.cancel();
    _watchdog = _timerFactory(_responseIdleTimeout, _onWatchdogTimeout);
  }

  void _disarmWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _onWatchdogTimeout() {
    if (!_active) {
      return;
    }
    // A lost response.done AFTER output audio stopped is also an unfinished
    // response (its audio is over, but the server never confirmed completion).
    final audioStoppedWithoutDone =
        _activeResponseId != null && _outputAudioStopped && !_responseDone;
    if (!_responseActive && !audioStoppedWithoutDone) {
      return;
    }
    // One terminal failure, one teardown, no second mint or response. When a
    // paid response may still be generating (audio not yet stopped) a
    // best-effort cancel/clear is sent; once the audio has already stopped none
    // is sent (playback is already over).
    unawaited(
      _failAndTeardown(
        OpenAIRealtimeVoiceFailure.responseTimeout,
        cancelActiveResponse: _responseActive,
      ),
    );
  }

  /// The non-empty nested `response.id` (response.created / response.done), or
  /// null if absent/empty/structurally invalid.
  static String? _nestedResponseId(Map<String, Object?> event) {
    final response = event['response'];
    if (response is Map) {
      return _asNonEmptyString(response['id']);
    }
    return null;
  }

  /// The non-empty top-level `response_id` (audio/output progress + stopped
  /// events), or null if absent/empty.
  static String? _topResponseId(Map<String, Object?> event) =>
      _asNonEmptyString(event['response_id']);

  static String? _asNonEmptyString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  // ---- Programmatic interrupt --------------------------------------------

  /// Programmatically interrupts the CURRENT active response (push-to-talk
  /// style). This is NOT [stop] / [dispose]: the WebRTC session — and, in
  /// `conversation`, the microphone — stay live.
  ///
  /// With no active response it is a completed no-op: no client event, no state
  /// or transport change, no mint/response.
  ///
  /// With an active response it does, EXACTLY ONCE (memoized across
  /// concurrent/repeat calls for that response):
  /// 1. finalizes an open assistant recording segment as an interrupted partial
  ///    (immediately — it never waits for a transcript before stopping audio);
  /// 2. stops the response watchdog and abandons the response;
  /// 3. sends over the existing DataChannel EXACTLY one `response.cancel`
  ///    immediately followed by one `output_audio_buffer.clear` — no wait for a
  ///    server ack, no retry. The clear is attempted even if the cancel throws.
  ///
  /// After a successful send the response is abandoned, so its late
  /// delta/audio/`response.done(status: cancelled)` are inert; a late valid
  /// FINAL assistant transcript for that (still-known) response is still handled
  /// by the existing final-transcript contract. No new response is created.
  /// In `conversation` the session returns to `listening` (WebRTC + mic stay
  /// live, ready for the next VAD turn); in `singleTurn` — whose one user turn is
  /// already closed — it ends as `ended` with exactly one transport close and NO
  /// second cancel/clear.
  ///
  /// A send failure surfaces ONLY one coarse
  /// [OpenAIRealtimeVoiceFailure.transport] with exactly-once teardown — no
  /// retry, reconnect, re-mint, second cancel/clear or new response, and the raw
  /// exception never reaches state or logs. A server `error` correlated (by the
  /// nested `error.event_id`) to the programmatic `response.cancel` — which the
  /// server may return when it had already finished the response — is
  /// RECOVERABLE and leaves the session live; an error correlated to the
  /// `output_audio_buffer.clear`, or any other error, stays terminal.
  Future<void> interruptResponse() {
    if (!_active) {
      return Future<void>.value();
    }
    final existing = _interrupt;
    if (existing != null) {
      // A concurrent/repeat call for the current response shares one operation.
      return existing;
    }
    if (_activeResponseId == null || !_responseActive) {
      // No active response → completed no-op (no events, no state change).
      return Future<void>.value();
    }
    return _interrupt = _interruptOnce();
  }

  Future<void> _interruptOnce() async {
    // Snapshot BEFORE mutating local state: the captured response id (so the
    // cancel can NEVER hit a newer response) and the turn epoch (so a newer
    // turn/response that arises during the sends is never overwritten).
    final responseId = _activeResponseId;
    final startEpoch = _turnEpoch;
    final transport = _transport;
    // Opaque INTERNAL client-event ids (never exported/logged; no user data).
    final cancelEventId = _nextClientEventId('pcx');
    final clearEventId = _nextClientEventId('pcl');

    // Guard against a second cancel/clear from a later teardown/watchdog.
    _responseCancelSent = true;
    // Finalize ONLY this response's open assistant segment as an interrupted
    // partial NOW; never wait for a transcript before stopping the audio, and
    // never touch a newer response's recording.
    if (responseId != null) {
      _recording?.interruptAssistantSegment(responseId);
    }
    _disarmWatchdog();
    // Abandon ONLY this response (keep _responseCancelSent = true) so its late
    // events are inert; a newer response, if it binds during the sends, is
    // untouched.
    if (_activeResponseId == responseId) {
      _activeResponseId = null;
      _responseActive = false;
      _responseDone = false;
      _outputAudioStopped = false;
    }

    if (transport == null) {
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      );
      return;
    }

    // Remember the recoverable-cancel correlation BEFORE sending, so a fast
    // server error can never race ahead of it.
    _recoverableCancelEventIds.add(cancelEventId);
    // Enqueue BOTH events SYNCHRONOUSLY (cancel then clear) before any await, so
    // no incoming event can slip between them and so the old interrupt cannot
    // cancel a response bound later. The cancel carries the CAPTURED response_id.
    // An error handler is attached to EACH send immediately (so a failed send is
    // never an unhandled async error), turning each into an ok/failed result;
    // both are then awaited. Both are attempted exactly once even if the cancel
    // fails — no retry.
    final cancelOk = transport
        .send(<String, Object?>{
          'type': 'response.cancel',
          'response_id': ?responseId,
          'event_id': cancelEventId,
        })
        .then((_) => true, onError: (Object _) => false);
    final clearOk = transport
        .send(<String, Object?>{
          'type': 'output_audio_buffer.clear',
          'event_id': clearEventId,
        })
        .then((_) => true, onError: (Object _) => false);
    final sendFailed = !(await cancelOk) || !(await clearOk);
    if (sendFailed) {
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      );
      return;
    }
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn) {
      // The one user turn is already closed → end the session. Exactly one
      // transport close; NO second cancel/clear (cancelActiveResponse: false).
      await (_teardown ??= _terminate(
        OpenAIRealtimeVoicePhase.ended,
        failure: null,
        cancelActiveResponse: false,
      ));
    } else if (_active && _turnEpoch == startEpoch) {
      // conversation: return to listening ONLY if nothing NEWER arose since the
      // interrupt began (no new user speech, no new active response, no
      // teardown). Otherwise leave the newer state untouched.
      _setPhase(OpenAIRealtimeVoicePhase.listening);
    }
  }

  // ---- Teardown ----------------------------------------------------------

  /// The one manual Stop. Idempotent; if a response is active it does one
  /// best-effort cancel + clear before exactly-once teardown. Never blocks on a
  /// still-pending connect; the transport's release closes any late resource.
  Future<void> stop() {
    if (!_active && _teardown == null) {
      // Never started or already terminal: no-op.
      return Future<void>.value();
    }
    _cancellation?.cancel();
    return _teardown ??= _terminate(
      OpenAIRealtimeVoicePhase.ended,
      failure: null,
      cancelActiveResponse: _responseActive,
    );
  }

  Future<void> _cancelAndClose() {
    return _teardown ??= _terminate(
      OpenAIRealtimeVoicePhase.ended,
      failure: null,
      cancelActiveResponse: false,
    );
  }

  Future<void> _failAndTeardown(
    OpenAIRealtimeVoiceFailure failure, {
    required bool cancelActiveResponse,
  }) {
    _cancellation?.cancel();
    return _teardown ??= _terminate(
      OpenAIRealtimeVoicePhase.failed,
      failure: failure,
      cancelActiveResponse: cancelActiveResponse,
    );
  }

  /// Exactly-once teardown: stop event processing, (best-effort) cancel/clear
  /// an active response, release the event subscription, the data channel, the
  /// local track/stream, the peer connection and the signaling HttpClient
  /// (owned by the transport), then emit the terminal state. A late resource
  /// materialized after the sweep is closed exactly once by the transport's
  /// release, and this settlement waits for that close.
  Future<void> _terminate(
    OpenAIRealtimeVoicePhase phase, {
    required OpenAIRealtimeVoiceFailure? failure,
    required bool cancelActiveResponse,
  }) async {
    _active = false;
    _recoverableCancelEventIds.clear();
    if (!_terminating.isCompleted) {
      // Unblock any pending recording track waiter on EVERY terminal path
      // (including a normal singleTurn auto-close), so no Future is left
      // pending. A value completion with no side effects — it does NOT release
      // the transport, so recordings still finalize before the sweep.
      _terminating.complete();
    }
    _disarmWatchdog();
    if (phase == OpenAIRealtimeVoicePhase.ended) {
      // A graceful close shows the transient stopping phase.
      _setPhase(OpenAIRealtimeVoicePhase.stopping);
    }
    if (cancelActiveResponse && !_responseCancelSent) {
      _responseCancelSent = true;
      await _bestEffortCancelActiveResponse();
    }
    // Finalize recordings while the WebRTC tracks/renderers still exist and
    // BEFORE the transport is released: any open segment is saved as the
    // actually-recorded interrupted fragment, pending files are flushed, and the
    // native writers are closed. A recording error is swallowed here — it never
    // blocks teardown and never changes the terminal state/failure.
    final recording = _recording;
    if (recording != null) {
      try {
        await recording.finalizeAndClose();
      } catch (_) {}
    }
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _transport?.close();
    _emit(OpenAIRealtimeVoiceState(phase: phase, failure: failure));
  }

  Future<void> _bestEffortCancelActiveResponse() async {
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

  /// Stops any live session (exactly once) and releases the state stream. After
  /// this, a later start() is rejected. Idempotent — repeat dispose()/stop()
  /// stay safe, and a dispose begun during an active start still cancels and
  /// releases the session.
  Future<void> dispose() async {
    _disposed = true;
    if (!_terminating.isCompleted) {
      // Covers dispose() before any start(): unblock a (defensive) waiter and
      // forbid a late attach without ever leaving a Future pending.
      _terminating.complete();
    }
    await stop();
    // Idempotent: covers dispose() before any start() (stop() was a no-op, so
    // the coordinator's recorders/timers are released here) and runs before the
    // recording streams are closed so any final flush still lands.
    final recording = _recording;
    if (recording != null) {
      try {
        await recording.finalizeAndClose();
      } catch (_) {}
    }
    if (!_states.isClosed) {
      await _states.close();
    }
    if (!_transcripts.isClosed) {
      await _transcripts.close();
    }
    if (!_assistantTranscriptDeltas.isClosed) {
      await _assistantTranscriptDeltas.close();
    }
    if (!_recordings.isClosed) {
      await _recordings.close();
    }
    if (!_recordingFailures.isClosed) {
      await _recordingFailures.close();
    }
  }
}

/// Package-internal test seam — NOT exported from the barrel. Injects the
/// private transport/clock seams so tests can drive the session
/// deterministically without native WebRTC or a real clock. Mirrors the core's
/// `chatSessionForTesting`; deliberately not a public constructor or DI surface
/// so the exported class keeps exactly the approved production shape.
@visibleForTesting
OpenAIRealtimeVoiceSession voiceSessionForTesting({
  required ClientSecretProvider clientSecretProvider,
  required BotProfile botProfile,
  required RealtimeVoiceTransportFactory transportFactory,
  OpenAIRealtimeVoiceMode mode = OpenAIRealtimeVoiceMode.singleTurn,
  String model = 'gpt-realtime-2.1',
  String voice = 'marin',
  int maxOutputTokens = 4096,
  Duration responseIdleTimeout = const Duration(seconds: 60),
  bool transcriptsEnabled = false,
  String inputTranscriptionModel = 'gpt-4o-mini-transcribe',
  bool recordingEnabled = false,
  String? recordingDirectoryPath,
  RealtimeVoiceRecorderFactory? recorderFactory,
  VoiceWatchdogTimerFactory timerFactory = _defaultWatchdogTimer,
}) => OpenAIRealtimeVoiceSession._(
  clientSecretProvider: clientSecretProvider,
  botProfile: botProfile,
  mode: mode,
  model: model,
  voice: voice,
  maxOutputTokens: maxOutputTokens,
  responseIdleTimeout: responseIdleTimeout,
  transcriptsEnabled: transcriptsEnabled,
  inputTranscriptionModel: inputTranscriptionModel,
  recordingEnabled: recordingEnabled,
  recordingDirectoryPath: recordingDirectoryPath,
  transportFactory: transportFactory,
  timerFactory: timerFactory,
  recorderFactory: recorderFactory,
);
