// The optional recording coordinator: it turns the session's already-VALIDATED
// lifecycle signals into ONE standalone `.m4a` file per spoken reply, pairs each
// file with the matching final transcript (when transcripts are enabled) and
// emits finished files / per-side failures on the session's two broadcast
// streams.
//
// Design guarantees (mirrors the money-safe / privacy rules of the session):
// - one file per reply, never a single mixed session file;
// - both sides recorded from the EXISTING WebRTC tracks — no second microphone;
// - a recording error is a SIDE CHANNEL only: it never ends the voice session,
//   never cancels a Response, never retries/reconnects/re-mints, and never blocks
//   the other side;
// - each file and each failure is emitted AT MOST ONCE;
// - every emitted recording / failure carries the reply's LOCAL turnId; a failure
//   is never anonymous. A side whose native tap failed to attach BEFORE any reply
//   remembers the breakage internally and surfaces its ONE failure only once a
//   concrete reply begins — tied to that reply's turnId, never early / id-less;
// - after [finalizeAndClose] no further event is ever emitted;
// - if audio is ready before its transcript, the file waits for a terminal
//   transcript outcome bounded by the session's existing responseIdleTimeout /
//   timer seam — never a new public timeout, never unbounded.
//
// The coordinator NEVER logs or stores a file path or a transcript.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'voice_recorder.dart';
import 'voice_recording.dart';

/// The timer seam (structurally the session's watchdog timer factory). Reused as
/// the bounded upper limit of an audio-ready-before-transcript wait.
typedef RecordingTimerFactory =
    Timer Function(Duration duration, void Function() onTimeout);

/// Process-global monotonic segment counter. Two coordinators (two sessions /
/// factory instances) therefore NEVER mint the same opaque segment id within a
/// process, so their native temp/final file names can never collide from a
/// per-session counter reset. (The native writer additionally derives a UUID
/// file name; this counter is the Dart-observable half of the collision fix.)
int _globalRecordingSegmentSeq = 0;

/// One reply's recording slot: the finalize result, the paired transcript state
/// and the exactly-once emission guard.
class _Slot {
  _Slot({
    required this.role,
    required this.pairingKey,
    required this.turnId,
    required this.segmentId,
  });

  final OpenAIRealtimeVoiceRecordingRole role;

  /// The internal pairing key (a user item id or an assistant response id). Kept
  /// only in memory; it never leaves the package.
  final String pairingKey;

  /// The reply's LOCAL turnId (UUID v4). Carried onto the emitted recording /
  /// failure so it correlates with the reply's transcript and deltas.
  final String turnId;

  /// The opaque per-file id handed to the native writer (never an item/response
  /// id, so no provider id reaches a file name).
  final String segmentId;

  bool open = false; // currently recording (begun, not yet ended)
  bool finalizing = false; // end requested; awaiting the native result
  bool finalized = false; // native result known
  bool interrupted = false; // ended by stop/cancel/barge-in
  bool beginFailed = false; // the native beginSegment could not be issued
  VoiceRecordingSegmentResult? result;

  bool transcriptResolved = false; // a terminal transcript outcome is known
  String? transcript; // text (may be '') or null (failed / timed out / absent)
  Timer? deadline;

  bool emitted = false;
}

/// Per-side state: one native recorder plus a serial op chain so begin/end can
/// never race even though the session dispatches event handlers unawaited.
class _Side {
  _Side(this.role, this.recorder);

  final OpenAIRealtimeVoiceRecordingRole role;
  final RealtimeVoiceRecorder recorder;

  /// Serialises the native commands in submission order.
  Future<void> chain = Future<void>.value();

  final Map<String, _Slot> slots = <String, _Slot>{};
  _Slot? openSlot;
  bool broken = false; // attach failed — the side cannot record
  bool attachFailureEmitted = false;
}

class VoiceRecordingCoordinator {
  VoiceRecordingCoordinator({
    required RealtimeVoiceRecorderFactory recorderFactory,
    required bool transcriptsEnabled,
    required Duration transcriptPairingTimeout,
    required RecordingTimerFactory timerFactory,
    required void Function(OpenAIRealtimeVoiceRecording recording) onRecording,
    required void Function(OpenAIRealtimeVoiceRecordingFailure failure)
    onFailure,
  }) : _recorderFactory = recorderFactory,
       _transcriptsEnabled = transcriptsEnabled,
       _transcriptPairingTimeout = transcriptPairingTimeout,
       _timerFactory = timerFactory,
       _onRecording = onRecording,
       _onFailure = onFailure;

  final RealtimeVoiceRecorderFactory _recorderFactory;
  final bool _transcriptsEnabled;
  final Duration _transcriptPairingTimeout;
  final RecordingTimerFactory _timerFactory;
  final void Function(OpenAIRealtimeVoiceRecording recording) _onRecording;
  final void Function(OpenAIRealtimeVoiceRecordingFailure failure) _onFailure;

  _Side? _user;
  _Side? _assistant;

  bool _flushing = false; // teardown: stop waiting on transcripts
  bool _disposed = false; // after finalizeAndClose: no further event
  Future<void>? _closing;

  // ---- Setup --------------------------------------------------------------

  /// Attaches the USER tap to the existing local track. Awaited by the session
  /// BEFORE the microphone is enabled so the onset is never clipped.
  Future<void> attachUser(String localTrackId) {
    if (_disposed) {
      return Future<void>.value();
    }
    final side = _user ??= _Side(
      OpenAIRealtimeVoiceRecordingRole.user,
      _recorderFactory(isRemote: false),
    );
    return _attach(side, localTrackId);
  }

  /// Attaches the ASSISTANT tap to the existing remote track (available well
  /// before the assistant ever speaks).
  Future<void> attachAssistant(String remoteTrackId) {
    if (_disposed) {
      return Future<void>.value();
    }
    final side = _assistant ??= _Side(
      OpenAIRealtimeVoiceRecordingRole.assistant,
      _recorderFactory(isRemote: true),
    );
    return _attach(side, remoteTrackId);
  }

  Future<void> _attach(_Side side, String trackId) {
    return _enqueue(side, () async {
      try {
        await side.recorder.attach(trackId: trackId);
      } catch (_) {
        // Remember the breakage; DO NOT emit an early, id-less failure. The one
        // failure for this side is surfaced when its first concrete reply begins,
        // tied to that reply's turnId (see [_begin]).
        side.broken = true;
      }
    });
  }

  // ---- User segmentation (verified VAD boundaries) ------------------------

  /// Begins a user reply's segment. The session has already verified the
  /// speech_started boundary (non-empty item id + non-negative audio_start_ms)
  /// and minted the reply's [turnId].
  void beginUserSegment(String itemId, String turnId) =>
      _begin(_user, itemId, turnId);

  /// Ends a user reply's segment on a verified speech_stopped boundary
  /// (matching item id, non-negative audio_end_ms >= audio_start_ms).
  void endUserSegment(String itemId) => _end(_user, itemId, interrupted: false);

  // ---- Assistant segmentation (output-audio boundaries) -------------------

  /// Begins the assistant segment on output_audio_buffer.started of the active
  /// response, tagged with the reply's [turnId].
  void beginAssistantSegment(String responseId, String turnId) =>
      _begin(_assistant, responseId, turnId);

  /// Ends the assistant segment on output_audio_buffer.stopped of the active
  /// response (a naturally completed reply).
  void endAssistantSegment(String responseId) =>
      _end(_assistant, responseId, interrupted: false);

  /// Ends the assistant segment as INTERRUPTED — the actually-played fragment —
  /// on a user barge-in / interrupt / guardrail block over the active response.
  void interruptAssistantSegment(String responseId) =>
      _end(_assistant, responseId, interrupted: true);

  void _begin(_Side? side, String pairingKey, String turnId) {
    if (side == null || _disposed) {
      return;
    }
    if (side.broken) {
      // The tap never attached. Surface the ONE per-side failure now — tied to
      // this concrete reply's turnId — then stop (a broken side cannot record).
      if (!side.attachFailureEmitted) {
        side.attachFailureEmitted = true;
        _onFailure(
          OpenAIRealtimeVoiceRecordingFailure(role: side.role, turnId: turnId),
        );
      }
      return;
    }
    if (side.openSlot != null) {
      // One active segment per side. While one is open, a duplicate / overlapping
      // / out-of-order boundary NEVER opens a second segment nor replaces or
      // destroys the in-progress one — it is simply dropped.
      return;
    }
    if (side.slots.containsKey(pairingKey)) {
      // This key was already recorded (or is finalizing) — never re-open it.
      return;
    }
    final slot = _Slot(
      role: side.role,
      pairingKey: pairingKey,
      turnId: turnId,
      segmentId: '${side.role.name}-seg-${_globalRecordingSegmentSeq++}',
    );
    slot.open = true;
    side.slots[pairingKey] = slot;
    side.openSlot = slot;
    _enqueue(side, () async {
      try {
        await side.recorder.beginSegment(slot.segmentId);
      } catch (_) {
        // The segment cannot record; it will finalize as a coarse failure.
        slot.beginFailed = true;
      }
    });
  }

  void _end(_Side? side, String pairingKey, {required bool interrupted}) {
    if (side == null || _disposed) {
      return;
    }
    final slot = side.slots[pairingKey];
    if (slot == null || !slot.open || slot.finalizing) {
      // No open segment for this key, or already ending — inert.
      return;
    }
    slot.open = false;
    slot.finalizing = true;
    slot.interrupted = interrupted;
    if (identical(side.openSlot, slot)) {
      side.openSlot = null;
    }
    _enqueue(side, () async {
      VoiceRecordingSegmentResult result;
      if (slot.beginFailed) {
        result = const VoiceRecordingSegmentResult.failed();
      } else {
        try {
          result = await side.recorder.endSegment(slot.segmentId);
        } catch (_) {
          result = const VoiceRecordingSegmentResult.failed();
        }
      }
      slot.result = result;
      slot.finalized = true;
      _tryEmit(side, slot);
    });
  }

  // ---- Transcript pairing (only fed VALID transcripts by the session) -----

  /// A terminal USER transcript for [itemId]: the completed text ([text], which
  /// may be an empty string) or null on a transcription failure. The session
  /// only calls this for a transcript it already validated and de-duplicated.
  void resolveUserTranscript(String itemId, {required String? text}) =>
      _resolveTranscript(_user, itemId, text);

  /// A terminal ASSISTANT transcript for [responseId] ([text] may be empty).
  void resolveAssistantTranscript(String responseId, {required String text}) =>
      _resolveTranscript(_assistant, responseId, text);

  void _resolveTranscript(_Side? side, String pairingKey, String? text) {
    if (side == null || _disposed) {
      return;
    }
    final slot = side.slots[pairingKey];
    if (slot == null || slot.transcriptResolved) {
      // Foreign / duplicate / already-terminal — never pair it.
      return;
    }
    slot.transcriptResolved = true;
    slot.transcript = text;
    slot.deadline?.cancel();
    slot.deadline = null;
    _tryEmit(side, slot);
  }

  // ---- Emission -----------------------------------------------------------

  void _tryEmit(_Side side, _Slot slot) {
    if (slot.emitted || _disposed) {
      return;
    }
    if (!slot.finalized) {
      return; // still recording / awaiting the native finalize result
    }
    final result = slot.result;
    if (result == null || !result.ok || result.filePath == null) {
      // A coarse per-side failure — never waits for a transcript.
      _finishSlot(side, slot);
      _onFailure(
        OpenAIRealtimeVoiceRecordingFailure(
          role: slot.role,
          turnId: slot.turnId,
        ),
      );
      return;
    }
    if (_transcriptsEnabled && !slot.transcriptResolved && !_flushing) {
      // Audio is ready before its transcript: wait, bounded by the existing
      // idle-timeout seam. No new public timeout.
      slot.deadline ??= _timerFactory(
        _transcriptPairingTimeout,
        () => _onDeadline(side, slot),
      );
      return;
    }
    _finishSlot(side, slot);
    _onRecording(
      OpenAIRealtimeVoiceRecording(
        role: slot.role,
        turnId: slot.turnId,
        filePath: result.filePath!,
        transcript: _transcriptsEnabled ? slot.transcript : null,
        interrupted: slot.interrupted,
      ),
    );
  }

  void _onDeadline(_Side side, _Slot slot) {
    if (slot.emitted || _disposed) {
      return;
    }
    // The transcript did not arrive in time: emit the file with a null
    // transcript. No retry / reconnect / re-mint / new Response.
    slot.transcriptResolved = true;
    slot.transcript = null;
    slot.deadline = null;
    _tryEmit(side, slot);
  }

  void _finishSlot(_Side side, _Slot slot) {
    slot.emitted = true;
    slot.deadline?.cancel();
    slot.deadline = null;
    side.slots.remove(slot.pairingKey);
  }

  // ---- Teardown -----------------------------------------------------------

  /// Finalizes any still-open segment as an interrupted fragment, flushes every
  /// pending file (with the transcript as-is — null if none arrived), closes
  /// both native recorders and forbids any further event. Idempotent /
  /// exactly-once; never throws.
  Future<void> finalizeAndClose() => _closing ??= _finalizeAndCloseOnce();

  Future<void> _finalizeAndCloseOnce() async {
    _flushing = true;

    // 1. Finalize any open segment as the actually-recorded interrupted fragment.
    for (final side in _sides) {
      final open = side.openSlot;
      if (open != null && !open.finalizing) {
        _end(side, open.pairingKey, interrupted: true);
      }
    }

    // 2. Drain the op chains so every finalize result is known and emitted.
    for (final side in _sides) {
      try {
        await side.chain;
      } catch (_) {}
    }

    // 3. Flush any slot that finalized but is still waiting on a transcript.
    for (final side in _sides) {
      for (final slot in side.slots.values.toList()) {
        if (!slot.emitted && slot.finalized) {
          slot.transcriptResolved = true;
          _tryEmit(side, slot);
        }
      }
    }

    // 4. No event may be emitted after this point.
    _disposed = true;
    for (final side in _sides) {
      for (final slot in side.slots.values) {
        slot.deadline?.cancel();
        slot.deadline = null;
      }
    }

    // 5. Close the native recorders (drops any leftover temp file).
    await Future.wait(<Future<void>>[
      for (final side in _sides) _guardClose(side.recorder),
    ]);
  }

  Iterable<_Side> get _sides => <_Side>[?_user, ?_assistant];

  static Future<void> _guardClose(RealtimeVoiceRecorder recorder) async {
    try {
      await recorder.close();
    } catch (_) {}
  }

  Future<void> _enqueue(_Side side, Future<void> Function() op) {
    final next = side.chain.then((_) => op());
    // Keep the chain non-failing so a later op always runs.
    side.chain = next.catchError((_) {});
    return next;
  }
}
