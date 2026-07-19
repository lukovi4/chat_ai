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
         transportFactory: _defaultTransportFactory,
         timerFactory: _defaultWatchdogTimer,
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
    required RealtimeVoiceTransportFactory transportFactory,
    required VoiceWatchdogTimerFactory timerFactory,
  }) : _provider = clientSecretProvider,
       _botProfile = botProfile,
       _mode = mode,
       _model = model,
       _voice = voice,
       _maxOutputTokens = maxOutputTokens,
       _responseIdleTimeout = responseIdleTimeout,
       _transcriptsEnabled = transcriptsEnabled,
       _inputTranscriptionModel = inputTranscriptionModel,
       _transportFactory = transportFactory,
       _timerFactory = timerFactory {
    _validate();
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
  final RealtimeVoiceTransportFactory _transportFactory;
  final VoiceWatchdogTimerFactory _timerFactory;

  final StreamController<OpenAIRealtimeVoiceState> _states =
      StreamController<OpenAIRealtimeVoiceState>.broadcast();
  OpenAIRealtimeVoiceState _state = const OpenAIRealtimeVoiceState.idle();

  // The optional final-transcript side channel. In-memory only, no history; it
  // exists at all only when the app opted in. Closed in dispose() alongside
  // [_states]; a terminal teardown forbids any further transcript event.
  final StreamController<OpenAIRealtimeVoiceTranscript> _transcripts =
      StreamController<OpenAIRealtimeVoiceTranscript>.broadcast();

  // Lifecycle guards.
  bool _startCalled = false; // start() is allowed exactly once.
  bool _disposed = false; // after dispose(), start() is rejected.
  bool _active = false; // a live session is processing events.
  RealtimeVoiceCancellation? _cancellation;
  RealtimeVoiceTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _eventsSub;
  Future<void>? _teardown; // memoized exactly-once teardown.

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
  }

  OpenAIRealtimeVoiceState get state => _state;
  Stream<OpenAIRealtimeVoiceState> get states => _states.stream;

  /// A broadcast stream of the OPTIONAL final transcripts, in the order the
  /// live session delivered them. Emits nothing unless `transcriptsEnabled` was
  /// set at construction. It carries only successfully-received FINAL text —
  /// user and assistant — and never deltas, ids, usage or a failure. Closed by
  /// [dispose].
  Stream<OpenAIRealtimeVoiceTranscript> get transcripts => _transcripts.stream;

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
        _onSpeechStarted();
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
      case 'response.output_audio_transcript.done':
        _onAssistantTranscriptDone(event);
      case 'error':
        await _onErrorEvent();
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
  void _maybeEnableMic() {
    if (!_active || _micEnabled || !_connectCompleted || !_sessionUpdatedAck) {
      return;
    }
    _micEnabled = true;
    _transport?.setMicrophoneEnabled(true);
    _setPhase(OpenAIRealtimeVoicePhase.listening);
  }

  void _onSpeechStarted() {
    if (!_active || !_micEnabled) {
      return;
    }
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn && _userTurnClosed) {
      // singleTurn accepts exactly one user turn; the mic is already off.
      return;
    }
    if (_responseActive) {
      // Barge-in: the server (interrupt_response: true) cancels the response
      // and truncates unplayed audio itself. We send NO redundant
      // response.cancel/truncate — only reflect the state and stop the
      // watchdog for the abandoned response.
      _abandonActiveResponse();
    }
    _setPhase(OpenAIRealtimeVoicePhase.userSpeaking);
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
    // The assistant's response follows (server VAD create_response).
    _setPhase(OpenAIRealtimeVoicePhase.assistantSpeaking);
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
    _setPhase(OpenAIRealtimeVoicePhase.assistantSpeaking);
    _kickWatchdog();
  }

  void _onOutputAudioStarted(Map<String, Object?> event) {
    if (!_active || !_matchesActiveResponse(_topResponseId(event))) {
      return;
    }
    _responseActive = true;
    _setPhase(OpenAIRealtimeVoicePhase.assistantSpeaking);
  }

  void _onOutputAudioStopped(Map<String, Object?> event) {
    // Accepted only with an exact response_id match of the active response.
    if (!_active || !_matchesActiveResponse(_topResponseId(event))) {
      return;
    }
    _outputAudioStopped = true;
    _responseActive = false;
    _disarmWatchdog();
    _evaluateResponseCompletion();
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
    _resolveUserTranscriptWait(itemId);
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

  Future<void> _onErrorEvent() async {
    if (!_active) {
      return;
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
    if (!_active || !_responseActive) {
      return;
    }
    // An active response went idle: one terminal failure, one best-effort
    // cancel/clear, one teardown. No second mint or response.
    unawaited(
      _failAndTeardown(
        OpenAIRealtimeVoiceFailure.responseTimeout,
        cancelActiveResponse: true,
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
    _disarmWatchdog();
    if (phase == OpenAIRealtimeVoicePhase.ended) {
      // A graceful close shows the transient stopping phase.
      _setPhase(OpenAIRealtimeVoicePhase.stopping);
    }
    if (cancelActiveResponse && !_responseCancelSent) {
      _responseCancelSent = true;
      await _bestEffortCancelActiveResponse();
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
    await stop();
    if (!_states.isClosed) {
      await _states.close();
    }
    if (!_transcripts.isClosed) {
      await _transcripts.close();
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
  transportFactory: transportFactory,
  timerFactory: timerFactory,
);
