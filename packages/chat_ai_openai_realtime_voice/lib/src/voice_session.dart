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
// The deliberate exceptions are the OPTIONAL text side channels: the final
// [transcripts], the assistant [assistantTranscriptDeltas] and the guardrail's
// accumulated text (passed only to the app callback). None of that text is ever
// logged or stored. Every reply carries a LOCAL [turnId] (UUID v4, never an
// OpenAI id) linking its delta / transcript / recording / recording-failure.
//
// This increment adds four universal capabilities to the same money-safe
// lifecycle:
// - an optional INITIAL HISTORY seeded as `conversation.item.create` items
//   (strictly ack-correlated) before the mic goes live;
// - universal TOOLS (core `Tool`/`ToolCall`/`ToolResult`/`OnToolCall`) with a
//   money-safe per-reply `maxToolTurns` bound;
// - an optional low-latency post-generation output GUARDRAIL that fails closed
//   with one no-context replacement;
// - unified local `turnId`s across the transcript / delta / recording streams.
// Tool continuations and the guardrail replacement are the only client-issued
// `response.create`s, and each is dispatched at most once (never a retry).
//
// One instance == one WebRTC session:
// - start() is allowed exactly once (a repeat is a programming error);
// - exactly one ClientSecretProvider call and one signaling POST;
// - no retry/reconnect/renewal;
// - stop()/dispose() are idempotent; late-materialized resources are closed
//   exactly once and start's settlement waits for that close.
//
// The private transport/clock seams live on the private constructor; the only
// public constructor is the approved production one. Tests reach the seams
// through the package-internal top-level [voiceSessionForTesting]; neither the
// seams nor that helper are ever exported from the barrel.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:chat_ai/chat_ai.dart'
    show BotProfile, Conversation, OnToolCall, Tool, ToolCall, ToolResult;
import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart'
    show ClientSecretProvider;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'voice_cancellation.dart';
import 'voice_guardrail.dart';
import 'voice_history.dart';
import 'voice_recorder.dart';
import 'voice_recording.dart';
import 'voice_recording_coordinator.dart';
import 'voice_session_update.dart';
import 'voice_state.dart';
import 'voice_tools.dart';
import 'voice_transcript.dart';
import 'voice_transport.dart';

/// Builds one fresh transport for the single Start (nothing is pooled).
typedef RealtimeVoiceTransportFactory = RealtimeVoiceTransport Function();

/// The one narrow clock seam for the response idle watchdog AND the guardrail's
/// fixed 250 ms throttle: a test provides a controllable timer so the money-safe
/// timeout and the guardrail schedule are deterministic. Not a scheduling
/// framework.
typedef VoiceWatchdogTimerFactory =
    Timer Function(Duration duration, void Function() onTimeout);

RealtimeVoiceTransport _defaultTransportFactory() =>
    WebRtcRealtimeVoiceTransport();

Timer _defaultWatchdogTimer(Duration duration, void Function() onTimeout) =>
    Timer(duration, onTimeout);

const Uuid _uuid = Uuid();

/// One extracted, well-formed Realtime function call of a completed response.
class _ToolCallLeg {
  const _ToolCallLeg({
    required this.callId,
    required this.name,
    required this.rawArguments,
  });

  final String callId;
  final String name;

  /// The raw `arguments` value from the wire (a JSON string per the API), left
  /// unparsed so an invalid payload becomes a sanitised error ToolResult.
  final Object? rawArguments;
}

class OpenAIRealtimeVoiceSession {
  /// The one public constructor. Validation is synchronous — an invalid model/
  /// voice/`maxOutputTokens`/`responseIdleTimeout`, an invalid tool/guardrail
  /// configuration or an invalid `initialConversation` throws an [ArgumentError]
  /// here, BEFORE any mint or network I/O.
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
    Conversation? initialConversation,
    OnToolCall? onToolCall,
    int maxToolTurns = 5,
    OpenAIRealtimeVoiceOutputGuardrail? outputGuardrail,
    String? safeReplacementInstructions,
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
         initialConversation: initialConversation,
         onToolCall: onToolCall,
         maxToolTurns: maxToolTurns,
         outputGuardrail: outputGuardrail,
         safeReplacementInstructions: safeReplacementInstructions,
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
    required Conversation? initialConversation,
    required OnToolCall? onToolCall,
    required int maxToolTurns,
    required OpenAIRealtimeVoiceOutputGuardrail? outputGuardrail,
    required String? safeReplacementInstructions,
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
       _onToolCall = onToolCall,
       _maxToolTurns = maxToolTurns,
       _outputGuardrail = outputGuardrail,
       _safeReplacementInstructions = safeReplacementInstructions,
       _transportFactory = transportFactory,
       _timerFactory = timerFactory {
    _validate();
    // Build the initial-history items synchronously (throws on an invalid
    // history), BEFORE any mint/network. The Conversation is read once and never
    // stored, mutated or normalised.
    _historyItems = initialConversation == null
        ? const <Map<String, Object?>>[]
        : prepareInitialHistory(initialConversation);
    _historySeeded = _historyItems.isEmpty;
    _toolsByName = <String, Tool>{
      for (final tool in _botProfile.tools) tool.name: tool,
    };
    if (_outputGuardrail != null) {
      _guardrail = OutputGuardrailRunner(
        guardrail: _outputGuardrail,
        timerFactory: _timerFactory,
        onViolation: _onGuardrailViolation,
      );
    }
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
  final OnToolCall? _onToolCall;
  final int _maxToolTurns;
  final OpenAIRealtimeVoiceOutputGuardrail? _outputGuardrail;
  final String? _safeReplacementInstructions;
  final RealtimeVoiceTransportFactory _transportFactory;
  final VoiceWatchdogTimerFactory _timerFactory;

  // Built once in the constructor body after synchronous validation.
  late final List<Map<String, Object?>> _historyItems;
  late final Map<String, Tool> _toolsByName;

  // The optional recording coordinator. Non-null only when the app opted in AND
  // a recorder factory exists (production always builds one).
  VoiceRecordingCoordinator? _recording;

  // The optional output guardrail scheduler. Non-null only when the app opted in
  // (both `outputGuardrail` and `safeReplacementInstructions` were supplied).
  OutputGuardrailRunner? _guardrail;

  bool get _toolsEnabled => _toolsByName.isNotEmpty && _onToolCall != null;
  bool get _guardrailEnabled => _guardrail != null;

  final StreamController<OpenAIRealtimeVoiceState> _states =
      StreamController<OpenAIRealtimeVoiceState>.broadcast();
  OpenAIRealtimeVoiceState _state = const OpenAIRealtimeVoiceState.idle();

  // The optional local-recording side channels.
  final StreamController<OpenAIRealtimeVoiceRecording> _recordings =
      StreamController<OpenAIRealtimeVoiceRecording>.broadcast();
  final StreamController<OpenAIRealtimeVoiceRecordingFailure>
  _recordingFailures =
      StreamController<OpenAIRealtimeVoiceRecordingFailure>.broadcast();

  // The single package-private VAD-pair state (works identically with recording
  // ON or OFF): the item id of the currently-open user speech segment (null when
  // none is open), its validated `audio_start_ms`, and the set of item ids that
  // have already completed a valid start→stop pair (so a reused id is rejected).
  String? _openVadItemId;
  int _openVadStartMs = 0;
  final Set<String> _usedVadItemIds = <String>{};

  // The optional final-transcript side channel.
  final StreamController<OpenAIRealtimeVoiceTranscript> _transcripts =
      StreamController<OpenAIRealtimeVoiceTranscript>.broadcast();

  // The OPTIONAL assistant transcript-DELTA side channel (only meaningful when
  // transcriptsEnabled). Each event now carries the reply's local turnId.
  final StreamController<OpenAIRealtimeVoiceTranscriptDelta>
  _assistantTranscriptDeltas =
      StreamController<OpenAIRealtimeVoiceTranscriptDelta>.broadcast();

  // The OPTIONAL coarse guardrail-event side channel (turnId only; no text).
  final StreamController<OpenAIRealtimeVoiceGuardrailEvent> _guardrailEvents =
      StreamController<OpenAIRealtimeVoiceGuardrailEvent>.broadcast();

  // Lifecycle guards.
  bool _startCalled = false;
  bool _disposed = false;
  bool _active = false;
  RealtimeVoiceCancellation? _cancellation;
  RealtimeVoiceTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _eventsSub;
  Future<void>? _teardown;
  final Completer<void> _terminating = Completer<void>();

  bool _sessionUpdateSent = false;
  bool _userTurnClosed = false;

  // Audio-readiness gate: the mic is enabled only once a successful
  // session.updated has arrived, connect() has returned AND (when supplied) the
  // whole initial history has been acknowledged.
  bool _connectCompleted = false;
  bool _sessionUpdatedAck = false;
  bool _micEnabled = false;

  // ---- Initial history seeding (before the mic goes live) -----------------
  late bool _historySeeded; // true once every history item is acknowledged
  bool _historySeedStarted = false;
  // Whether ONE history item is currently awaiting its conversation.item.added
  // (history is sent strictly one item at a time, so at most one ack can be
  // outstanding), the completer resolved on that ack, and the deadline that
  // stops a lost ack from freezing the session in `connecting` forever.
  bool _awaitingHistoryAck = false;
  Completer<void>? _historyAck;
  Timer? _historyAckTimer;

  // Current response tracking (money-safe watchdog + completion).
  String? _activeResponseId;
  bool _responseActive = false;
  bool _responseDone = false;
  bool _outputAudioStopped = false;
  bool _responseCancelSent = false;
  Timer? _watchdog;
  Future<void>? _interrupt;
  int _clientEventSeq = 0;
  final Set<String> _recoverableCancelEventIds = <String>{};
  int _turnEpoch = 0;

  // ---- Local turnIds ------------------------------------------------------
  // The current user speech turn's local id (minted on speech_started).
  String? _userTurnId;
  // user item_id → user turnId (for attributing the async user transcript).
  final Map<String, String> _userTurnIdByItem = <String, String>{};
  // The current assistant reply's local id (minted on the first response.created
  // of a logical reply; preserved across tool legs; new on a replacement).
  String? _assistantTurnId;
  // response id → assistant turnId (so a late assistant transcript is attributed
  // even after a barge-in abandoned the active response).
  final Map<String, String> _assistantTurnIdByResponse = <String, String>{};
  // Response ids of assistant replies that were interrupted (barge-in /
  // interruptResponse / guardrail block) — so a late final transcript carries
  // `interrupted: true`.
  final Set<String> _interruptedResponseIds = <String>{};

  // ---- Tools --------------------------------------------------------------
  // Resolver invocations counted per LOGICAL assistant reply (reset when a fresh
  // reply — not a tool continuation — binds).
  int _toolTurnCount = 0;
  // The next response.created continues the current tool chain (keep turnId +
  // count) rather than starting a fresh reply.
  bool _expectingToolContinuation = false;
  // The identity token of the CURRENT pending tool operation (null when none is
  // pending). A pending resolver is correlated with its own token so that a
  // stale/interrupted operation clears only ITSELF and can never touch a newer
  // operation's pending state. interruptResponse(), barge-in, a new valid user
  // turn and dispose invalidate the current operation by clearing this token;
  // the resolver re-checks the token after it returns (and before sending), so a
  // late result of a superseded/interrupted operation is fully inert.
  int? _pendingToolToken;
  int _toolTokenSeq = 0;
  // call_ids already processed — a repeat is a terminal protocol error.
  final Set<String> _executedToolCallIds = <String>{};

  // ---- Guardrail replacement ----------------------------------------------
  // At most one guardrail replacement per USER TURN (reset in _onSpeechStarted).
  bool _grReplacementUsed = false;
  bool _expectingReplacement =
      false; // the next response.created is the replacement
  String? _pendingReplacementTurnId;
  // The mandatory exact-final guardrail flow for the current audio reply
  // (defect 6). The authoritative final text comes from
  // response.output_audio_transcript.done; the turn closes only after the
  // guardrail allows that exact final text.
  bool _grFinalStarted = false; // the exact-final check was kicked (once)
  bool? _grAllowed; // null = pending, true = allowed, false = blocked
  bool _grAwaitingFinal = false; // completion is waiting for the final verdict

  // ---- Deferred final-transcript publication (defect 3) -------------------
  // The validated authoritative final transcript of the current reply, HELD
  // until the reply's outcome is decided. It is published exactly once — with
  // `interrupted: false` only after a valid final transcript AND
  // response.done(completed) AND output_audio_buffer.stopped AND (when guardrail
  // is enabled) an allow verdict AND no interruption; otherwise with
  // `interrupted: true`. It is NEVER published `false` first and then corrected.
  String? _pendingFinalText;
  String? _pendingFinalTurnId;

  String _nextClientEventId(String prefix) => '${prefix}_${_clientEventSeq++}';

  /// Publishes the held final transcript (if any) exactly once, with the decided
  /// [interrupted] flag, then clears it. No-op when nothing is held.
  void _publishPendingFinal({required bool interrupted}) {
    final text = _pendingFinalText;
    final turnId = _pendingFinalTurnId;
    if (text == null || turnId == null) {
      return;
    }
    _pendingFinalText = null;
    _pendingFinalTurnId = null;
    if (_transcriptsEnabled) {
      _emitTranscript(
        OpenAIRealtimeVoiceTranscriptRole.assistant,
        turnId,
        text,
        interrupted: interrupted,
      );
    }
  }

  String _newTurnId() => _uuid.v4();

  // ---- Optional transcript attribution (only when _transcriptsEnabled) -----
  final Set<String> _knownUserItemIds = <String>{};
  final Set<String> _resolvedUserItemIds = <String>{};
  final Set<String> _emittedAssistantKeys = <String>{};
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
    // Tools: maxToolTurns must be positive; non-empty tools require a resolver;
    // names / duplicates / JSON Schema are validated by the Chat AI Tool Schema
    // v1 dialect — all BEFORE any mint/network.
    if (_maxToolTurns <= 0) {
      throw ArgumentError.value(
        _maxToolTurns,
        'maxToolTurns',
        'must be greater than 0',
      );
    }
    if (_botProfile.tools.isNotEmpty) {
      if (_onToolCall == null) {
        throw ArgumentError.value(
          null,
          'onToolCall',
          'onToolCall is required when botProfile.tools is non-empty',
        );
      }
      validateVoiceToolDeclarations(_botProfile.tools);
    }
    // Guardrail: both values present or both absent; replacement instructions
    // must be non-empty — synchronously, BEFORE any mint.
    final hasGuardrail = _outputGuardrail != null;
    final hasReplacement = _safeReplacementInstructions != null;
    if (hasGuardrail != hasReplacement) {
      throw ArgumentError(
        'outputGuardrail and safeReplacementInstructions must both be set or '
        'both be null',
      );
    }
    if (hasGuardrail && _safeReplacementInstructions!.trim().isEmpty) {
      throw ArgumentError.value(
        _safeReplacementInstructions,
        'safeReplacementInstructions',
        'must not be empty when an output guardrail is set',
      );
    }
    if (_transcriptsEnabled && _inputTranscriptionModel.trim().isEmpty) {
      throw ArgumentError.value(
        _inputTranscriptionModel,
        'inputTranscriptionModel',
        'must not be empty when transcriptsEnabled is true',
      );
    }
    if (_recordingEnabled) {
      // The exception is SANITIZED: it names only the parameter and the rule,
      // never the offending path value.
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

  /// A broadcast stream of the OPTIONAL final transcripts, in delivery order.
  /// Emits nothing unless `transcriptsEnabled` was set at construction. Each
  /// event carries the reply's local `turnId`, an `interrupted` flag and the
  /// final text (user or assistant) — never deltas, ids, usage or a failure.
  /// Closed by [dispose].
  Stream<OpenAIRealtimeVoiceTranscript> get transcripts => _transcripts.stream;

  /// A broadcast stream of the assistant transcript DELTAS of the current
  /// response, in arrival order. Each [OpenAIRealtimeVoiceTranscriptDelta]
  /// carries the reply's local `turnId` and the raw `delta` String, passed
  /// through EXACTLY as received (never trimmed, merged, deduplicated or
  /// accumulated). Emits nothing unless `transcriptsEnabled` was set. Closed by
  /// [dispose].
  Stream<OpenAIRealtimeVoiceTranscriptDelta> get assistantTranscriptDeltas =>
      _assistantTranscriptDeltas.stream;

  /// A broadcast stream of coarse guardrail events. Each carries ONLY the
  /// blocked reply's local `turnId` — never the text, the classifier reason,
  /// provider ids or any raw detail. Emits nothing unless an `outputGuardrail`
  /// was set. Closed by [dispose].
  Stream<OpenAIRealtimeVoiceGuardrailEvent> get guardrailEvents =>
      _guardrailEvents.stream;

  /// A broadcast stream of finished per-reply recordings, in finalize order.
  /// Emits nothing unless `recordingEnabled` was set. Each event carries the
  /// reply's local `turnId`, the app-owned `.m4a` path, the optional paired
  /// transcript and the [OpenAIRealtimeVoiceRecording.interrupted] flag. Closed
  /// by [dispose].
  Stream<OpenAIRealtimeVoiceRecording> get recordings => _recordings.stream;

  /// A broadcast stream of coarse per-side recording failures (role + turnId).
  /// A recording failure is a SIDE CHANNEL: it never becomes a session failure,
  /// never ends the session and never triggers a retry/reconnect/mint. Closed by
  /// [dispose].
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

  /// The one manual Start.
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
      final secret = await _provider.getClientSecret(botId: _botProfile.id);
      if (_isCancelled()) {
        throw const RealtimeVoiceConnectCancelled();
      }

      _setPhase(OpenAIRealtimeVoicePhase.connecting);
      final transport = _transportFactory();
      _transport = transport;

      _eventsSub = transport.events.listen(
        (event) => unawaited(_onEvent(event)),
        onDone: _onEventsDone,
        onError: (_) {},
      );

      await transport.connect(secret, cancellation);
      if (_isCancelled()) {
        throw const RealtimeVoiceConnectCancelled();
      }

      _connectCompleted = true;
      _maybeStartHistorySeeding();
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
    _maybeKickWatchdog(type, event);
    switch (type) {
      case 'session.created':
        await _sendSessionUpdateOnce();
      case 'session.updated':
        _onSessionUpdated();
      case 'conversation.item.added':
        _onHistoryItemAdded(event);
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
      await transport.send(
        buildRealtimeVoiceSessionUpdate(
          model: _model,
          voice: _voice,
          instructions: _botProfile.systemPrompt,
          maxOutputTokens: _maxOutputTokens,
          transcriptsEnabled: _transcriptsEnabled,
          inputTranscriptionModel: _inputTranscriptionModel,
          tools: _botProfile.tools,
        ),
      );
    } catch (_) {
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
    _sessionUpdatedAck = true;
    _maybeStartHistorySeeding();
    _maybeEnableMic();
  }

  // ---- Initial history seeding -------------------------------------------

  /// Starts the initial-history seeding exactly once, and ONLY when BOTH gates
  /// are open: `transport.connect()` has fully returned AND a valid
  /// `session.updated` has been acknowledged. `session.updated` can arrive over
  /// the data channel while `connect()` is still in flight, so seeding driven by
  /// that event alone would send `conversation.item.create` on a not-yet-ready
  /// connection. Called from exactly two places — after `_connectCompleted` in
  /// `start()` and after `_sessionUpdatedAck` here — so whichever happens last
  /// opens the gate. The mic keeps its own separate gate in `_maybeEnableMic()`.
  void _maybeStartHistorySeeding() {
    if (!_active ||
        !_connectCompleted ||
        !_sessionUpdatedAck ||
        _historyItems.isEmpty ||
        _historySeedStarted) {
      return;
    }
    _historySeedStarted = true;
    unawaited(_seedHistory());
  }

  /// Sends each prepared history item as a `conversation.item.create`, waiting
  /// for its `conversation.item.added` before the next one. Exactly ONE item
  /// is in flight at a time (the mic is off and no `response.create` is sent),
  /// so any well-formed acknowledgement while an item is pending belongs to it.
  /// The mic is armed only after the WHOLE history is acknowledged. A send
  /// error, a transport death, a HUNG send or a LOST ack is a terminal `session`
  /// failure — the mic never enables, the next item is never sent, there is no
  /// retry/reconnect/re-mint, and a late ack or a late send result is inert. One
  /// `responseIdleTimeout` deadline bounds each item's WHOLE operation: the
  /// `conversation.item.create` send AND the wait for its acknowledgement.
  Future<void> _seedHistory() async {
    final transport = _transport;
    if (transport == null) {
      return;
    }
    for (final item in _historyItems) {
      if (!_active) {
        _clearHistoryAckWait();
        return;
      }
      final ack = Completer<void>();
      _awaitingHistoryAck = true;
      _historyAck = ack;
      // Bound the WHOLE operation — the send itself AND the wait for the ack.
      // The deadline is armed BEFORE the send so that a hung
      // `conversation.item.create` can never leave this Future — and the
      // session's phase — pending forever.
      _historyAckTimer?.cancel();
      _historyAckTimer = _timerFactory(
        _responseIdleTimeout,
        _onHistoryAckTimeout,
      );
      try {
        await transport.send(<String, Object?>{
          'type': 'conversation.item.create',
          'item': item,
        });
      } catch (_) {
        // A send error that lands AFTER the deadline (or a stop/dispose) already
        // tore the session down is inert: the error is swallowed here, so there
        // is no second failure and no unhandled Zone error.
        _clearHistoryAckWait();
        if (_active) {
          await _failAndTeardown(
            OpenAIRealtimeVoiceFailure.session,
            cancelActiveResponse: false,
          );
        }
        return;
      }
      if (!_active) {
        _clearHistoryAckWait();
        return;
      }
      // Wait for the ack OR a terminal teardown. (An ack that already arrived
      // while the send was in flight has completed `ack` and cancelled the
      // deadline above, so this returns at once and the next item starts.)
      await Future.any<void>(<Future<void>>[ack.future, _terminating.future]);
      if (!_active || !ack.isCompleted) {
        _clearHistoryAckWait();
        return;
      }
    }
    _clearHistoryAckWait();
    _historySeeded = true;
    _maybeEnableMic();
  }

  /// Confirms the awaited history item when a WELL-FORMED
  /// `conversation.item.added` arrives while exactly one item is pending. A
  /// malformed event (no `item`, a non-Map `item`, or a missing/empty/non-String
  /// `item.id`) confirms nothing and the wait continues. `conversation.item.added`
  /// is the ONLY acknowledgement: the `conversation.item.done` that follows it is
  /// not dispatched here (and no other event type is), so it confirms nothing.
  void _onHistoryItemAdded(Map<String, Object?> event) {
    if (!_awaitingHistoryAck) {
      return;
    }
    final item = event['item'];
    if (item is! Map || !_isNonEmptyString(item['id'])) {
      return;
    }
    final ack = _historyAck;
    _clearHistoryAckWait();
    if (ack != null && !ack.isCompleted) {
      ack.complete();
    }
  }

  /// The awaited `conversation.item.added` never arrived: terminal `session`
  /// failure (no mic, no next item, no retry/reconnect/re-mint).
  void _onHistoryAckTimeout() {
    if (!_active || !_awaitingHistoryAck) {
      return;
    }
    _clearHistoryAckWait();
    unawaited(
      _failAndTeardown(
        OpenAIRealtimeVoiceFailure.session,
        cancelActiveResponse: false,
      ),
    );
  }

  /// Ends the current history wait and cancels its deadline (on an ack, on a
  /// send failure, on the last item, and on any stop / dispose / teardown).
  void _clearHistoryAckWait() {
    _awaitingHistoryAck = false;
    _historyAck = null;
    _historyAckTimer?.cancel();
    _historyAckTimer = null;
  }

  /// Enables the one microphone track exactly once, and ONLY when a successful
  /// session.updated has been acknowledged, transport.connect() has fully
  /// returned AND the whole initial history has been acknowledged.
  void _maybeEnableMic() {
    if (!_active ||
        _micEnabled ||
        !_connectCompleted ||
        !_sessionUpdatedAck ||
        !_historySeeded) {
      return;
    }
    _micEnabled = true;
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
    final localId = transport.localAudioTrackId;
    if (localId != null && localId.isNotEmpty) {
      try {
        await recording.attachUser(localId);
      } catch (_) {}
    }
    if (!_active) {
      return;
    }
    transport.setMicrophoneEnabled(true);
    _setPhase(OpenAIRealtimeVoicePhase.listening);
    unawaited(_attachAssistantRecorder(recording, transport));
  }

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
      return;
    }
    try {
      await recording.attachAssistant(remoteId);
    } catch (_) {}
  }

  /// A strictly-validated `input_audio_buffer.speech_started` (defect 4). A
  /// valid start requires a non-empty `item_id`, a non-negative `audio_start_ms`,
  /// NO already-open user speech segment, and an `item_id` not already used by a
  /// completed pair. Malformed / duplicate / overlapping / reused events are
  /// FULLY INERT (no turnId, no epoch, no tool-op invalidation, no
  /// replacement-budget reset, no barge-in, no phase change, no recording). This
  /// runs identically with recording ON or OFF.
  void _onSpeechStarted(Map<String, Object?> event) {
    if (!_active || !_micEnabled) {
      return;
    }
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn && _userTurnClosed) {
      return;
    }
    // ---- Strict validation BEFORE any state change. ----
    final itemId = _asNonEmptyString(event['item_id']);
    final startMs = event['audio_start_ms'];
    if (itemId == null || !_isNonNegativeInt(startMs)) {
      return; // malformed → inert
    }
    if (_openVadItemId != null) {
      return; // a segment is already open (duplicate / overlapping) → inert
    }
    if (_usedVadItemIds.contains(itemId)) {
      return; // this item id already completed a pair (reused) → inert
    }

    // ---- Only now does a valid user turn actually begin. ----
    _openVadItemId = itemId;
    _openVadStartMs = startMs! as int;
    // A new user turn is a newer state than any in-flight interrupt, and it
    // invalidates the previous pending tool operation and re-opens the one
    // guardrail replacement budget for THIS user turn.
    _turnEpoch++;
    _pendingToolToken = null;
    _grReplacementUsed = false;
    // Exactly one UUID v4 user turnId, associated with this item id.
    _userTurnId = _newTurnId();
    _userTurnIdByItem[itemId] = _userTurnId!;
    if (_responseActive) {
      // Barge-in: the server cancels/truncates. We send NO redundant
      // response.cancel/truncate — only reflect the state, interrupt the
      // recording, drop the guardrail context and publish the pending final
      // transcript (if any) as interrupted.
      final responseId = _activeResponseId;
      if (responseId != null) {
        _interruptedResponseIds.add(responseId);
        _recording?.interruptAssistantSegment(responseId);
      }
      _guardrail?.cancelTurn();
      _publishPendingFinal(interrupted: true);
      _abandonActiveResponse();
    }
    _recording?.beginUserSegment(itemId, _userTurnId!);
    _setPhase(OpenAIRealtimeVoicePhase.userSpeaking);
  }

  /// A strictly-validated `input_audio_buffer.speech_stopped` (defect 4). A valid
  /// stop requires the SAME non-empty `item_id` as the open start, a non-negative
  /// `audio_end_ms`, and `audio_end_ms >= audio_start_ms`. A stop with no open
  /// segment, a foreign item id or a malformed value is FULLY INERT — it never
  /// closes singleTurn, disables the mic, changes phase or registers a transcript
  /// item.
  void _onSpeechStopped(Map<String, Object?> event) {
    if (!_active || !_micEnabled) {
      return;
    }
    final openItemId = _openVadItemId;
    if (openItemId == null) {
      return; // no open user segment (stop without start / foreign) → inert
    }
    final itemId = _asNonEmptyString(event['item_id']);
    final endMs = event['audio_end_ms'];
    if (itemId != openItemId ||
        !_isNonNegativeInt(endMs) ||
        (endMs! as int) < _openVadStartMs) {
      return; // malformed / foreign / out-of-order → inert
    }

    // ---- Only now does the user turn actually close. ----
    _openVadItemId = null;
    _openVadStartMs = 0;
    _usedVadItemIds.add(openItemId);
    _recording?.endUserSegment(openItemId);
    _registerUserTranscriptItem(openItemId);
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn) {
      _userTurnClosed = true;
      _transport?.setMicrophoneEnabled(false);
    }
    _setPhase(OpenAIRealtimeVoicePhase.assistantSpeaking);
  }

  /// Registers a VALIDATED user reply item id for transcript attribution (its
  /// turnId was already minted on the matching speech_started). No-op unless
  /// transcripts are enabled. In singleTurn it also latches the first reply whose
  /// transcription terminal outcome the auto-close waits for.
  void _registerUserTranscriptItem(String itemId) {
    if (!_transcriptsEnabled) {
      return;
    }
    _knownUserItemIds.add(itemId);
    _userTurnIdByItem[itemId] ??= _userTurnId ?? _newTurnId();
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
      return;
    }
    final id = _nestedResponseId(event);
    if (id == null) {
      unawaited(
        _failAndTeardown(
          OpenAIRealtimeVoiceFailure.transport,
          cancelActiveResponse: false,
        ),
      );
      return;
    }
    _activeResponseId = id;
    // Reset the per-response exact-final-guardrail flow and any held final
    // transcript from a previous response.
    _grFinalStarted = false;
    _grAllowed = null;
    _grAwaitingFinal = false;
    _pendingFinalText = null;
    _pendingFinalTurnId = null;
    // Bind the assistant turnId for this response.
    if (_expectingToolContinuation) {
      // A tool continuation keeps the SAME logical reply's turnId and count.
      _expectingToolContinuation = false;
      _assistantTurnId ??= _newTurnId();
    } else if (_expectingReplacement) {
      // The one allowed guardrail replacement gets a fresh turnId and a fresh
      // guardrail context / tool count.
      _expectingReplacement = false;
      _assistantTurnId = _pendingReplacementTurnId ?? _newTurnId();
      _pendingReplacementTurnId = null;
      _toolTurnCount = 0;
      _guardrail?.beginTurn(_assistantTurnId!);
    } else {
      // A fresh logical assistant reply.
      _assistantTurnId = _newTurnId();
      _toolTurnCount = 0;
      _guardrail?.beginTurn(_assistantTurnId!);
    }
    _assistantTurnIdByResponse[id] = _assistantTurnId!;
    _responseActive = true;
    _responseDone = false;
    _outputAudioStopped = false;
    _responseCancelSent = false;
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
    final responseId = _activeResponseId;
    if (responseId != null) {
      _recording?.beginAssistantSegment(
        responseId,
        _assistantTurnIdByResponse[responseId] ?? _assistantTurnId ?? '',
      );
    }
    _setPhase(OpenAIRealtimeVoicePhase.assistantSpeaking);
  }

  void _onOutputAudioStopped(Map<String, Object?> event) {
    if (!_active || !_matchesActiveResponse(_topResponseId(event))) {
      return;
    }
    if (_outputAudioStopped) {
      return;
    }
    _outputAudioStopped = true;
    _responseActive = false;
    final responseId = _activeResponseId;
    if (!_guardrailEnabled) {
      // Normal path: close the assistant segment now (not interrupted).
      if (responseId != null) {
        _recording?.endAssistantSegment(responseId);
      }
    }
    // With a guardrail the assistant segment is finalized only after the
    // mandatory final check (interrupted on a block, otherwise not).
    if (_responseDone) {
      _disarmWatchdog();
      _evaluateResponseCompletion();
    } else {
      _kickWatchdog();
    }
  }

  void _onResponseDone(Map<String, Object?> event) {
    if (!_active || !_matchesActiveResponse(_nestedResponseId(event))) {
      return;
    }
    final response = event['response'];
    final status = response is Map ? response['status'] : null;
    if (status == 'completed') {
      // A completed response may carry a tool call (a tool leg) rather than an
      // audio reply. A tool leg never waits for output_audio_buffer.stopped.
      if (_toolsEnabled && response is Map) {
        final calls = _functionCallItems(response);
        if (calls.length >= 2) {
          // Defect 1: `parallel_tool_calls: false` is always sent, so two or more
          // `function_call` items is a protocol violation. Terminate immediately
          // (no resolver, no output/create, no timeout wait, one teardown); the
          // raw payload is never published or logged.
          unawaited(
            _failAndTeardown(
              OpenAIRealtimeVoiceFailure.transport,
              cancelActiveResponse: false,
            ),
          );
          return;
        }
        if (calls.length == 1) {
          final fc = calls.first;
          final callId = fc['call_id'];
          final name = fc['name'];
          if (callId is! String ||
              callId.isEmpty ||
              name is! String ||
              name.isEmpty) {
            // Defect 4 (P1): a single function_call item with a missing/empty
            // call_id or name is a malformed protocol event — never mistaken for
            // an audio completion. Terminate immediately.
            unawaited(
              _failAndTeardown(
                OpenAIRealtimeVoiceFailure.transport,
                cancelActiveResponse: false,
              ),
            );
            return;
          }
          _handleToolLeg(
            _ToolCallLeg(
              callId: callId,
              name: name,
              rawArguments: fc['arguments'],
            ),
          );
          return;
        }
        // Zero function_call items → an ordinary audio completion.
      }
      _responseDone = true;
      _evaluateResponseCompletion();
      return;
    }
    unawaited(
      _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      ),
    );
  }

  // ---- Tools --------------------------------------------------------------

  /// ALL `function_call` output items of a completed response (raw, so a
  /// malformed one — missing/empty call_id or name — can be detected by the
  /// caller). With `parallel_tool_calls: false` a well-formed response has at
  /// most one; two or more is a protocol violation the caller rejects.
  List<Map<Object?, Object?>> _functionCallItems(
    Map<Object?, Object?> response,
  ) {
    final output = response['output'];
    if (output is! List) {
      return const <Map<Object?, Object?>>[];
    }
    return <Map<Object?, Object?>>[
      for (final item in output)
        if (item is Map<Object?, Object?> && item['type'] == 'function_call')
          item,
    ];
  }

  void _handleToolLeg(_ToolCallLeg call) {
    // The tool leg's response is done; abandon it (no audio to wait for). The
    // assistant turnId is preserved across the whole tool chain.
    _disarmWatchdog();
    final responseId = _activeResponseId;
    if (responseId != null && _activeResponseId == responseId) {
      _activeResponseId = null;
      _responseActive = false;
      _responseDone = false;
      _outputAudioStopped = false;
    }
    if (_executedToolCallIds.contains(call.callId)) {
      // Defect 2: a repeat call_id is a protocol violation. It is a terminal
      // transport failure (exactly-once teardown) — the resolver is not run
      // again, no output/create is re-sent, no watchdog/Future is left pending
      // and there is no retry.
      unawaited(
        _failAndTeardown(
          OpenAIRealtimeVoiceFailure.transport,
          cancelActiveResponse: false,
        ),
      );
      return;
    }
    if (_toolTurnCount >= _maxToolTurns) {
      // The over-limit resolver is never started: no function_call_output, no
      // new response.create — terminal toolLoopLimit.
      unawaited(
        _failAndTeardown(
          OpenAIRealtimeVoiceFailure.toolLoopLimit,
          cancelActiveResponse: false,
        ),
      );
      return;
    }
    _executedToolCallIds.add(call.callId);
    _toolTurnCount++;
    // Correlate this pending tool operation with its own identity token.
    final token = ++_toolTokenSeq;
    _pendingToolToken = token;
    unawaited(_resolveAndReply(call, token, _turnEpoch));
  }

  /// True when the tool operation identified by ([token], [epoch]) is no longer
  /// the current, actual one (the session died, the operation's token was cleared
  /// or replaced by a newer one, or the logical turn moved). If the operation is
  /// stale but its token is still OURS (only `_active`/epoch changed), releases
  /// that token so it never dangles; a token already taken over by an
  /// interrupter is left untouched.
  bool _toolOperationStale(int token, int epoch) {
    if (_active && _pendingToolToken == token && _turnEpoch == epoch) {
      return false;
    }
    if (_pendingToolToken == token) {
      _pendingToolToken = null;
    }
    return true;
  }

  Future<void> _resolveAndReply(_ToolCallLeg call, int token, int epoch) async {
    final result = await _computeToolResult(call);
    // Check #1 — after the resolver. A stale / interrupted operation sends
    // nothing and clears no state it does not own. The ownership token is NOT
    // consumed here: it stays owned through the whole send sequence below so an
    // interrupt landing during the (possibly-gated) function_call_output send is
    // still detected before response.create.
    if (_toolOperationStale(token, epoch)) {
      return;
    }
    final transport = _transport;
    if (transport == null) {
      _pendingToolToken = null;
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      );
      return;
    }
    // Send exactly one function_call_output. An ambiguous send failure is NOT
    // retried — one terminal transport failure.
    bool outputOk;
    try {
      await transport.send(<String, Object?>{
        'type': 'conversation.item.create',
        'item': <String, Object?>{
          'type': 'function_call_output',
          'call_id': call.callId,
          'output': encodeToolResultOutput(result),
        },
      });
      outputOk = true;
    } catch (_) {
      outputOk = false;
    }
    // Check #2 — after the function_call_output send, immediately BEFORE
    // response.create. If the operation went stale during that send window
    // (interrupt / barge-in / new user turn / stop / dispose), a late success OR
    // error is fully inert: no response.create, no failure — and the try/catch
    // above already consumed any error so there is no unhandled Zone error.
    if (_toolOperationStale(token, epoch)) {
      return;
    }
    if (!outputOk) {
      _pendingToolToken = null;
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      );
      return;
    }
    // Ownership is still ours and the output landed → dispatch EXACTLY one
    // response.create (same logical reply / assistant turnId). Release ownership
    // now that the operation is committing; no retry after this dispatch.
    _pendingToolToken = null;
    _expectingToolContinuation = true;
    try {
      await transport.send(<String, Object?>{'type': 'response.create'});
    } catch (_) {
      _expectingToolContinuation = false;
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      );
    }
  }

  Future<ToolResult> _computeToolResult(_ToolCallLeg call) async {
    final tool = _toolsByName[call.name];
    if (tool == null) {
      // Unknown tool — the resolver is never called.
      return const ToolResult(content: 'unknown tool', isError: true);
    }
    final raw = call.rawArguments;
    final args = raw is String ? parseToolArguments(raw) : null;
    if (args == null) {
      // Malformed / non-object JSON — the resolver is never called.
      return const ToolResult(content: 'invalid arguments', isError: true);
    }
    if (!toolArgsMatchSchema(tool.parameters, args)) {
      // The arguments do not conform to the tool's Chat AI Tool Schema v1
      // declaration — the resolver is never called. Neither the schema nor the
      // raw arguments reach the wire, state, events or logs.
      return const ToolResult(content: 'invalid arguments', isError: true);
    }
    try {
      return await _onToolCall!(
        ToolCall(id: call.callId, name: call.name, args: args),
      );
    } catch (_) {
      // The exception text and stack trace are NEVER sent or logged.
      return const ToolResult(content: 'tool execution failed', isError: true);
    }
  }

  // ---- Completion ---------------------------------------------------------

  void _evaluateResponseCompletion() {
    if (!(_responseDone && _outputAudioStopped)) {
      return;
    }
    // The reply is considered complete only after the guardrail allowed the
    // AUTHORITATIVE exact final transcript (defect 6). The final check is driven
    // by response.output_audio_transcript.done; here we only gate the close.
    if (_guardrailEnabled) {
      if (_grAllowed == false) {
        // Blocked: the fail-closed replacement owns it. Do NOT close the turn.
        return;
      }
      if (_grAllowed == null) {
        // The exact final transcript / verdict has not arrived yet. Wait for it.
        // If the authoritative final transcript has NOT yet arrived, bound the
        // wait by the EXISTING response idle watchdog (no new timeout); a lost
        // final transcript then ends the turn as a controlled responseTimeout. If
        // it HAS arrived (the guardrail check is running), the callback bounds it.
        if (!_grFinalStarted && !_grAwaitingFinal) {
          _grAwaitingFinal = true;
          _armFinalTranscriptDeadline();
        }
        return;
      }
      // Allowed: finalize the (deferred) assistant recording segment now.
      _grAwaitingFinal = false;
      final responseId = _activeResponseId;
      if (responseId != null) {
        _recording?.endAssistantSegment(responseId);
      }
    }
    // The reply is complete and clean (done + stopped + guardrail-allow + no
    // interruption): publish the held final transcript now with interrupted:false,
    // BEFORE any singleTurn user-transcript wait.
    _publishPendingFinal(interrupted: false);
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn &&
        _awaitingUserTranscript()) {
      _armUserTranscriptDeadline();
      return;
    }
    _disarmWatchdog();
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn) {
      _guardrail?.cancelTurn();
      unawaited(
        _teardown ??= _terminate(
          OpenAIRealtimeVoicePhase.ended,
          failure: null,
          cancelActiveResponse: false,
        ),
      );
    } else {
      _guardrail?.cancelTurn();
      _resetResponseState();
      _setPhase(OpenAIRealtimeVoicePhase.listening);
    }
  }

  /// Reuses the single watchdog/timer seam as the upper bound for the wait on the
  /// authoritative final transcript when audio completion arrived first. On
  /// expiry the reply ends as a controlled [OpenAIRealtimeVoiceFailure.responseTimeout]
  /// — no retry, reconnect, mint or new Response.
  void _armFinalTranscriptDeadline() {
    _watchdog?.cancel();
    _watchdog = _timerFactory(_responseIdleTimeout, _onFinalTranscriptDeadline);
  }

  void _onFinalTranscriptDeadline() {
    if (!_active || !_grAwaitingFinal) {
      return;
    }
    unawaited(
      _failAndTeardown(
        OpenAIRealtimeVoiceFailure.responseTimeout,
        cancelActiveResponse: false,
      ),
    );
  }

  /// Kicks the mandatory exact-final guardrail check for the current reply with
  /// the AUTHORITATIVE [finalText] (from transcript.done). Runs once per reply;
  /// the public final transcript is published only by [_onGuardrailFinalVerdict],
  /// gated on the verdict.
  void _startGuardrailFinal(
    String responseId,
    String turnId,
    String finalText,
  ) {
    if (_grFinalStarted) {
      return;
    }
    _grFinalStarted = true;
    if (_grAwaitingFinal) {
      // The authoritative final transcript has now arrived, satisfying the
      // transcript-wait deadline armed at audio completion; the guardrail
      // callback (one at a time) now bounds progress — no new timeout.
      _grAwaitingFinal = false;
      _disarmWatchdog();
    }
    unawaited(
      _guardrail!.finalize(turnId, finalText: finalText).then((allowed) {
        _onGuardrailFinalVerdict(responseId, turnId, finalText, allowed);
      }),
    );
  }

  void _onGuardrailFinalVerdict(
    String responseId,
    String turnId,
    String finalText,
    bool allowed,
  ) {
    if (!_active) {
      return;
    }
    if (allowed && !_interruptedResponseIds.contains(responseId)) {
      // The exact final passed and the reply was not interrupted: the held final
      // transcript will be published (interrupted:false) by
      // _evaluateResponseCompletion once audio completion is also met.
      _grAllowed = true;
      _evaluateResponseCompletion();
      return;
    }
    // Blocked, OR interrupted while the verdict was in flight. On a block the
    // fail-closed path (via _onGuardrailViolation) publishes the held final
    // transcript interrupted:true; on an interruption the interrupt path already
    // published it. Publishing here is a no-op if it was already published.
    _grAllowed = false;
    _publishPendingFinal(interrupted: true);
    // On a block the fail-closed replacement (via _onGuardrailViolation) already
    // ran; on a barge-in the abandon path already handled it.
  }

  bool _awaitingUserTranscript() =>
      _transcriptsEnabled &&
      _mode == OpenAIRealtimeVoiceMode.singleTurn &&
      _pendingUserItemId != null &&
      !_userTranscriptResolved;

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

  void _resolveUserTranscriptWait(String itemId) {
    if (_mode != OpenAIRealtimeVoiceMode.singleTurn ||
        itemId != _pendingUserItemId ||
        _userTranscriptResolved) {
      return;
    }
    _userTranscriptResolved = true;
    _maybeFinishSingleTurn();
  }

  void _maybeFinishSingleTurn() {
    if (!(_responseDone && _outputAudioStopped) || _teardown != null) {
      return;
    }
    _disarmWatchdog();
    _guardrail?.cancelTurn();
    unawaited(
      _teardown ??= _terminate(
        OpenAIRealtimeVoicePhase.ended,
        failure: null,
        cancelActiveResponse: false,
      ),
    );
  }

  // ---- Optional final transcripts ----------------------------------------

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
      return;
    }
    final turnId = _userTurnIdByItem[itemId] ?? _newTurnId();
    _emitTranscript(
      OpenAIRealtimeVoiceTranscriptRole.user,
      turnId,
      transcript,
      interrupted: false,
    );
    _recording?.resolveUserTranscript(itemId, text: transcript);
    _resolveUserTranscriptWait(itemId);
  }

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
    _recording?.resolveUserTranscript(itemId, text: null);
    _resolveUserTranscriptWait(itemId);
  }

  void _onAssistantTranscriptDelta(Map<String, Object?> event) {
    if (!_active) {
      return;
    }
    // The guardrail consumes assistant transcript deltas INTERNALLY even when
    // the public transcript streams are off; it never auto-enables input ASR.
    if (!_transcriptsEnabled && !_guardrailEnabled) {
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
    final turnId = _assistantTurnIdByResponse[responseId] ?? _assistantTurnId;
    if (turnId == null) {
      return;
    }
    if (_transcriptsEnabled && !_assistantTranscriptDeltas.isClosed) {
      _assistantTranscriptDeltas.add(
        OpenAIRealtimeVoiceTranscriptDelta(turnId: turnId, delta: delta),
      );
    }
    _guardrail?.addDelta(turnId, delta);
  }

  void _onAssistantTranscriptDone(Map<String, Object?> event) {
    if (!_active) {
      return;
    }
    // The guardrail needs the authoritative final transcript INTERNALLY even
    // when the public transcript stream is off (defect 6); it never publishes a
    // transcript that is disabled.
    if (!_transcriptsEnabled && !_guardrailEnabled) {
      return;
    }
    final responseId = _asNonEmptyString(event['response_id']);
    if (responseId == null ||
        !_assistantTurnIdByResponse.containsKey(responseId)) {
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
      // Duplicate final event — exactly-once.
      return;
    }
    final turnId = _assistantTurnIdByResponse[responseId]!;
    // The recording pairs with the exact final text as soon as it is known; the
    // recording's own `interrupted` flag comes from its segment, independent of
    // the public transcript event's timing.
    _recording?.resolveAssistantTranscript(responseId, text: transcript);

    if (_matchesActiveResponse(responseId) &&
        !_interruptedResponseIds.contains(responseId)) {
      // The authoritative exact final transcript of the CURRENT, not-yet-
      // interrupted reply. HOLD it (defect 3) — it is published only when the
      // reply's outcome is decided: `interrupted:false` after a clean completion,
      // or `interrupted:true` on any interruption before then. Never published
      // `false` first and then corrected.
      _pendingFinalText = transcript;
      _pendingFinalTurnId = turnId;
      if (_guardrailEnabled) {
        // The exact-final guardrail callback still fires immediately; only the
        // PUBLICATION of the public transcript is delayed.
        _startGuardrailFinal(responseId, turnId, transcript);
      } else {
        // Guardrail off: if the audio reply already completed, publish now
        // (interrupted:false); otherwise the held final publishes at completion
        // or on an interruption.
        if (_responseDone && _outputAudioStopped) {
          _evaluateResponseCompletion();
        }
      }
      return;
    }
    // A late final transcript of an already-interrupted / abandoned response (or
    // one whose response is no longer active): publish once with interrupted:true.
    // It starts no new guardrail / replacement.
    if (_transcriptsEnabled) {
      _emitTranscript(
        OpenAIRealtimeVoiceTranscriptRole.assistant,
        turnId,
        transcript,
        interrupted: _interruptedResponseIds.contains(responseId),
      );
    }
  }

  void _emitTranscript(
    OpenAIRealtimeVoiceTranscriptRole role,
    String turnId,
    String text, {
    required bool interrupted,
  }) {
    if (_transcripts.isClosed) {
      return;
    }
    _transcripts.add(
      OpenAIRealtimeVoiceTranscript(
        role: role,
        turnId: turnId,
        text: text,
        interrupted: interrupted,
      ),
    );
  }

  // ---- Output guardrail ---------------------------------------------------

  /// The runner reports a first block / callback exception here (exactly once
  /// per turn). Fails closed: cancel → clear → interrupted recording → one
  /// coarse event → one no-context replacement (or terminal `guardrail` when the
  /// block is inside the one allowed replacement).
  void _onGuardrailViolation(String turnId) {
    if (!_active) {
      return;
    }
    unawaited(_failClosed(turnId));
  }

  Future<void> _failClosed(String turnId) async {
    if (!_active) {
      return;
    }
    final transport = _transport;
    final responseId = _activeResponseId;
    final isReplacementBlock = _grReplacementUsed;
    // Bind this fail-closed / replacement operation to the ORIGINAL assistant
    // turn/epoch, so a newer turn (barge-in / new user speech) or a teardown that
    // lands during the gated cancel/clear supersedes it before the replacement
    // response.create is dispatched.
    final startEpoch = _turnEpoch;
    _responseCancelSent = true;

    // 3 + 4: finalize the original assistant recording as interrupted; the
    // original turn stays interrupted (a late final transcript carries it too).
    if (responseId != null) {
      _interruptedResponseIds.add(responseId);
      _recording?.interruptAssistantSegment(responseId);
    }
    // A held final transcript of the blocked reply is published interrupted:true.
    _publishPendingFinal(interrupted: true);
    _disarmWatchdog();
    // Abandon the original response so its late events are inert.
    if (_activeResponseId == responseId) {
      _activeResponseId = null;
      _responseActive = false;
      _responseDone = false;
      _outputAudioStopped = false;
    }
    // 5: publish exactly one coarse guardrail event (turnId only).
    if (!_guardrailEvents.isClosed) {
      _guardrailEvents.add(OpenAIRealtimeVoiceGuardrailEvent(turnId: turnId));
    }

    if (transport == null) {
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.guardrail,
        cancelActiveResponse: false,
      );
      return;
    }

    // 1 + 2: enqueue the targeted cancel then the clear (cancel immediately
    // before clear). The cancel is recoverable-correlated so the server's
    // "nothing to cancel" error (when the reply already finished) stays inert.
    final cancelEventId = _nextClientEventId('pgx');
    final clearEventId = _nextClientEventId('pgl');
    _recoverableCancelEventIds.add(cancelEventId);
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

    // Ownership re-check AFTER the gated cancel/clear, immediately BEFORE the
    // replacement dispatch. If a newer turn arose (barge-in / new valid user
    // speech) or the session was torn down (stop / dispose) during that gate, the
    // replacement is fully superseded: no replacement response.create is sent, no
    // late terminal failure is raised, and the newer state (e.g. userSpeaking) is
    // left untouched. A late cancel/clear success or error stays inert (the
    // `.then(onError:)` above already consumed any error — no unhandled Zone
    // error).
    if (!_active || _turnEpoch != startEpoch) {
      return;
    }

    if (isReplacementBlock) {
      // A block inside the one allowed replacement is terminal — no second
      // replacement is ever created.
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.guardrail,
        cancelActiveResponse: false,
      );
      return;
    }
    if (sendFailed) {
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      );
      return;
    }
    // 6: create EXACTLY one replacement response with a new assistant turnId and
    // the exact no-context / no-tools payload. No retry after this dispatch.
    _grReplacementUsed = true;
    _pendingReplacementTurnId = _newTurnId();
    _expectingReplacement = true;
    bool createOk;
    try {
      await transport.send(<String, Object?>{
        'type': 'response.create',
        'response': <String, Object?>{
          'input': <Object?>[],
          'tools': <Object?>[],
          'instructions': _safeReplacementInstructions,
        },
      });
      createOk = true;
    } catch (_) {
      createOk = false;
    }
    if (!createOk) {
      _expectingReplacement = false;
      _pendingReplacementTurnId = null;
      await _failAndTeardown(
        OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      );
    }
  }

  Future<void> _onErrorEvent(Map<String, Object?> event) async {
    if (!_active) {
      return;
    }
    final error = event['error'];
    if (error is Map) {
      final eventId = error['event_id'];
      if (eventId is String && _recoverableCancelEventIds.contains(eventId)) {
        return;
      }
    }
    final setup = _isSetupPhase();
    await _failAndTeardown(
      setup
          ? OpenAIRealtimeVoiceFailure.session
          : OpenAIRealtimeVoiceFailure.transport,
      cancelActiveResponse: _responseActive,
    );
  }

  void _onEventsDone() {
    if (!_active) {
      return;
    }
    final setup = _isSetupPhase();
    unawaited(
      _failAndTeardown(
        setup
            ? OpenAIRealtimeVoiceFailure.session
            : OpenAIRealtimeVoiceFailure.transport,
        cancelActiveResponse: false,
      ),
    );
  }

  bool _isSetupPhase() =>
      _state.phase == OpenAIRealtimeVoicePhase.minting ||
      _state.phase == OpenAIRealtimeVoicePhase.connecting;

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

  static bool _isResponseProgress(String type, Map<String, Object?> event) {
    switch (type) {
      case 'response.output_audio.delta':
      case 'response.output_audio_transcript.delta':
        return _hasItemAndIndices(event) && _isNonEmptyString(event['delta']);
      case 'response.output_audio.done':
        return _hasItemAndIndices(event);
      case 'response.output_audio_transcript.done':
        return _hasItemAndIndices(event) && event['transcript'] is String;
      case 'response.content_part.added':
      case 'response.content_part.done':
        return _hasItemAndIndices(event) && event['part'] is Map;
      case 'response.output_item.added':
      case 'response.output_item.done':
        return _isNonNegativeInt(event['output_index']) &&
            _isItemWithType(event['item']);
      case 'output_audio_buffer.started':
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
    final audioStoppedWithoutDone =
        _activeResponseId != null && _outputAudioStopped && !_responseDone;
    if (!_responseActive && !audioStoppedWithoutDone) {
      return;
    }
    unawaited(
      _failAndTeardown(
        OpenAIRealtimeVoiceFailure.responseTimeout,
        cancelActiveResponse: _responseActive,
      ),
    );
  }

  static String? _nestedResponseId(Map<String, Object?> event) {
    final response = event['response'];
    if (response is Map) {
      return _asNonEmptyString(response['id']);
    }
    return null;
  }

  static String? _topResponseId(Map<String, Object?> event) =>
      _asNonEmptyString(event['response_id']);

  static String? _asNonEmptyString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  // ---- Programmatic interrupt --------------------------------------------

  /// Programmatically interrupts the CURRENT active response (see the barrel
  /// docs). With no active response it is a completed no-op.
  Future<void> interruptResponse() {
    if (!_active) {
      return Future<void>.value();
    }
    final existing = _interrupt;
    if (existing != null) {
      return existing;
    }
    if (_activeResponseId != null && _responseActive) {
      // An active audio response — cancel/clear it (unchanged).
      return _interrupt = _interruptOnce();
    }
    if (_pendingToolToken != null) {
      // A pending tool resolver is part of the current logical reply. Interrupt
      // exactly THIS operation WITHOUT a meaningless response.cancel (nothing is
      // generating audio); its late resolver result is dropped.
      return _interrupt = _interruptToolChain();
    }
    // Nothing to interrupt — a completed no-op.
    return Future<void>.value();
  }

  /// Interrupts a logical reply whose only in-flight work is a pending tool
  /// resolver (no active server generation / audio). Invalidates the resolver so
  /// its late result never continues the tool chain, drops the guardrail
  /// context, and returns the session to a resting state — with NO
  /// response.cancel/clear, no new Response, and no retry/reconnect/mint.
  Future<void> _interruptToolChain() async {
    // Invalidate exactly the current pending operation (clear its token) and bump
    // the epoch so its late result is dropped; clear the tool-continuation intent
    // so the chain cannot resume.
    _pendingToolToken = null;
    _turnEpoch++;
    _expectingToolContinuation = false;
    _guardrail?.cancelTurn();
    _disarmWatchdog();
    if (_mode == OpenAIRealtimeVoiceMode.singleTurn) {
      // The one user turn is already closed → end the session (one teardown, no
      // second cancel/clear).
      await (_teardown ??= _terminate(
        OpenAIRealtimeVoicePhase.ended,
        failure: null,
        cancelActiveResponse: false,
      ));
    } else if (_state.phase == OpenAIRealtimeVoicePhase.assistantSpeaking) {
      // conversation: only reset to listening if nothing newer (e.g. a barge-in)
      // already moved the state on.
      _setPhase(OpenAIRealtimeVoicePhase.listening);
    }
  }

  Future<void> _interruptOnce() async {
    final responseId = _activeResponseId;
    final startEpoch = _turnEpoch;
    final transport = _transport;
    final cancelEventId = _nextClientEventId('pcx');
    final clearEventId = _nextClientEventId('pcl');

    _responseCancelSent = true;
    if (responseId != null) {
      _interruptedResponseIds.add(responseId);
      _recording?.interruptAssistantSegment(responseId);
    }
    // The interrupted reply's guardrail context is dropped, and a held final
    // transcript is published interrupted:true.
    _guardrail?.cancelTurn();
    _publishPendingFinal(interrupted: true);
    _disarmWatchdog();
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

    _recoverableCancelEventIds.add(cancelEventId);
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
      await (_teardown ??= _terminate(
        OpenAIRealtimeVoicePhase.ended,
        failure: null,
        cancelActiveResponse: false,
      ));
    } else if (_active && _turnEpoch == startEpoch) {
      _setPhase(OpenAIRealtimeVoicePhase.listening);
    }
  }

  // ---- Teardown ----------------------------------------------------------

  Future<void> stop() {
    if (!_active && _teardown == null) {
      return Future<void>.value();
    }
    // A stop during an active response leaves it interrupted (a late final
    // transcript, if the stream is still open, would carry interrupted: true).
    final responseId = _activeResponseId;
    if (responseId != null && _responseActive) {
      _interruptedResponseIds.add(responseId);
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

  Future<void> _terminate(
    OpenAIRealtimeVoicePhase phase, {
    required OpenAIRealtimeVoiceFailure? failure,
    required bool cancelActiveResponse,
  }) async {
    _active = false;
    _recoverableCancelEventIds.clear();
    // Drop any pending guardrail check and unblock a waiting final check.
    _guardrail?.cancelTurn();
    // A held final transcript that never reached a clean publication (a teardown
    // during a live reply) is published interrupted:true (no-op if a clean
    // completion already published it).
    _publishPendingFinal(interrupted: true);
    if (!_terminating.isCompleted) {
      _terminating.complete();
    }
    _disarmWatchdog();
    // Any outstanding initial-history wait (and its deadline) ends here — on a
    // stop, a dispose or a failure — so no timer outlives the session.
    _clearHistoryAckWait();
    if (phase == OpenAIRealtimeVoicePhase.ended) {
      _setPhase(OpenAIRealtimeVoicePhase.stopping);
    }
    if (cancelActiveResponse && !_responseCancelSent) {
      _responseCancelSent = true;
      await _bestEffortCancelActiveResponse();
    }
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
    } catch (_) {}
  }

  Future<void> dispose() async {
    _disposed = true;
    _guardrail?.dispose();
    if (!_terminating.isCompleted) {
      _terminating.complete();
    }
    await stop();
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
    if (!_guardrailEvents.isClosed) {
      await _guardrailEvents.close();
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
/// private transport/clock seams so tests can drive the session deterministically
/// without native WebRTC or a real clock.
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
  Conversation? initialConversation,
  OnToolCall? onToolCall,
  int maxToolTurns = 5,
  OpenAIRealtimeVoiceOutputGuardrail? outputGuardrail,
  String? safeReplacementInstructions,
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
  initialConversation: initialConversation,
  onToolCall: onToolCall,
  maxToolTurns: maxToolTurns,
  outputGuardrail: outputGuardrail,
  safeReplacementInstructions: safeReplacementInstructions,
  transportFactory: transportFactory,
  timerFactory: timerFactory,
  recorderFactory: recorderFactory,
);
