// The narrow native-writer surface the recording coordinator drives, and its
// production iOS implementation over ONE method channel.
//
// This channel carries COMMANDS ONLY — a writer id, a local/remote flag, an
// opaque segment id, the output directory and the safe scalar recording-format
// numbers. PCM, audio buffers, bytes or base64 NEVER cross it: the native side
// attaches to the EXISTING WebRTC track as a public RTCAudioRenderer and writes
// each `.m4a` file entirely on the iOS side. The only value that ever comes BACK
// is a finished file's path (a safe string), never audio.
//
// One recorder instance owns exactly one side (local user OR remote assistant)
// and produces ONE file per reply through repeated beginSegment/endSegment.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/services.dart';

/// The one method channel name; kept in sync with the native plugin.
const String kVoiceRecorderChannel = 'chat_ai_openai_realtime_voice/recorder';

/// Thrown by a recorder command that could not be issued. Carries no native
/// message, path or track id — the coordinator maps it to a coarse per-side
/// failure event.
class RealtimeVoiceRecorderException implements Exception {
  const RealtimeVoiceRecorderException();
  @override
  String toString() => 'RealtimeVoiceRecorderException';
}

/// The coarse result of finalizing one segment: whether a valid, non-empty file
/// was produced and, if so, its app-owned path. NEVER carries audio, native
/// status or a raw error. finalize does not throw for an invalid result.
class VoiceRecordingSegmentResult {
  const VoiceRecordingSegmentResult({required this.ok, this.filePath});

  const VoiceRecordingSegmentResult.failed() : ok = false, filePath = null;

  final bool ok;

  /// Set (non-null) only when [ok] is true.
  final String? filePath;
}

/// One continuously-attached native audio writer for a single side.
///
/// The renderer is attached at [attach] time — BEFORE the microphone goes live —
/// so the very start of a reply is never clipped; the native tap keeps a bounded
/// pre-roll and each [beginSegment] flushes it, so segmentation by the verified
/// VAD / output-audio boundaries never drops the onset. All operations are
/// idempotent / exactly-once on the Dart side; the native side is idempotent
/// too.
abstract class RealtimeVoiceRecorder {
  /// Attaches the continuous tap to the existing WebRTC [trackId] (a LOCAL track
  /// id for the user side, a REMOTE track id for the assistant side) and remembers
  /// the output directory and format. Throws [RealtimeVoiceRecorderException] on
  /// failure. Must be called before the microphone is enabled.
  Future<void> attach({required String trackId});

  /// Opens a new per-reply segment (opaque [segmentId]). The bounded pre-roll is
  /// flushed into it so the onset is preserved. Throws
  /// [RealtimeVoiceRecorderException] on failure.
  Future<void> beginSegment(String segmentId);

  /// Finalizes the current segment, converts/encodes it and validates it, then
  /// returns a coarse [VoiceRecordingSegmentResult]. NEVER throws for an invalid
  /// result. An invalid / empty temporary file is deleted by the native side; a
  /// valid file is left in the app-owned directory and its path returned.
  Future<VoiceRecordingSegmentResult> endSegment(String segmentId);

  /// Detaches the tap, drops any still-open (unfinalized) segment's temporary
  /// file and releases native resources. Idempotent; a native failure never
  /// propagates (teardown must not throw).
  Future<void> close();
}

/// Builds one [RealtimeVoiceRecorder] per side. Injectable so tests drive the
/// coordinator/session with a Dart-only fake and assert that no audio ever
/// crosses the boundary.
typedef RealtimeVoiceRecorderFactory =
    RealtimeVoiceRecorder Function({required bool isRemote});

/// The production factory: native iOS writers over the one shared method
/// channel, targeting [directoryPath] with the fixed speech-recording format
/// (m4a / AAC-LC / 16 kHz / mono / 32 kbit/s — the `record_transcribe`
/// speechDefault).
class NativeRealtimeVoiceRecorderFactory {
  NativeRealtimeVoiceRecorderFactory({
    required String directoryPath,
    MethodChannel? channel,
  }) : _directoryPath = directoryPath,
       _channel = channel ?? const MethodChannel(kVoiceRecorderChannel);

  final String _directoryPath;
  final MethodChannel _channel;
  int _seq = 0;

  RealtimeVoiceRecorder create({required bool isRemote}) {
    final id = '${isRemote ? 'assistant' : 'user'}-${_seq++}';
    return NativeRealtimeVoiceRecorder(
      channel: _channel,
      writerId: id,
      isRemote: isRemote,
      directoryPath: _directoryPath,
    );
  }

  /// A [RealtimeVoiceRecorderFactory] bound to this factory instance.
  RealtimeVoiceRecorder call({required bool isRemote}) =>
      create(isRemote: isRemote);
}

/// The fixed speech-recording format — identical to
/// `record_transcribe`'s `RecordingProfile.speechDefault()`.
class VoiceRecordingFormat {
  const VoiceRecordingFormat._();
  static const String container = 'm4a';
  static const int sampleRate = 16000;
  static const int numChannels = 1;
  static const int bitRate = 32000;

  /// Bounded pre-roll flushed into each new segment so a reply's onset is not
  /// clipped by VAD / signaling latency. Small enough that it is only lead-in,
  /// never inter-reply content.
  static const int preRollMs = 300;
}

/// The production native writer. start/finalize/close are exactly-once on the
/// Dart side too.
class NativeRealtimeVoiceRecorder implements RealtimeVoiceRecorder {
  NativeRealtimeVoiceRecorder({
    required MethodChannel channel,
    required this.writerId,
    required this.isRemote,
    required String directoryPath,
  }) : _channel = channel,
       _directoryPath = directoryPath;

  final MethodChannel _channel;
  final String writerId;
  final bool isRemote;
  final String _directoryPath;

  bool _attached = false;
  bool _closed = false;

  @override
  Future<void> attach({required String trackId}) async {
    if (_attached || _closed) {
      return;
    }
    _attached = true;
    try {
      await _channel.invokeMethod<void>('attach', <String, Object?>{
        'writerId': writerId,
        'isRemote': isRemote,
        'trackId': trackId,
        'directoryPath': _directoryPath,
        'sampleRate': VoiceRecordingFormat.sampleRate,
        'numChannels': VoiceRecordingFormat.numChannels,
        'bitRate': VoiceRecordingFormat.bitRate,
        'preRollMs': VoiceRecordingFormat.preRollMs,
      });
    } on PlatformException {
      throw const RealtimeVoiceRecorderException();
    }
  }

  @override
  Future<void> beginSegment(String segmentId) async {
    if (_closed) {
      throw const RealtimeVoiceRecorderException();
    }
    try {
      await _channel.invokeMethod<void>('beginSegment', <String, Object?>{
        'writerId': writerId,
        'segmentId': segmentId,
      });
    } on PlatformException {
      throw const RealtimeVoiceRecorderException();
    }
  }

  @override
  Future<VoiceRecordingSegmentResult> endSegment(String segmentId) async {
    if (_closed) {
      return const VoiceRecordingSegmentResult.failed();
    }
    Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<Object?, Object?>(
        'endSegment',
        <String, Object?>{'writerId': writerId, 'segmentId': segmentId},
      );
    } on PlatformException {
      // Even a platform failure is a diagnosable, non-throwing outcome.
      return const VoiceRecordingSegmentResult.failed();
    }
    final ok = result?['ok'] == true;
    final filePath = result?['filePath'];
    if (ok && filePath is String && filePath.isNotEmpty) {
      return VoiceRecordingSegmentResult(ok: true, filePath: filePath);
    }
    return const VoiceRecordingSegmentResult.failed();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _channel.invokeMethod<void>('close', <String, Object?>{
        'writerId': writerId,
      });
    } catch (_) {
      // Swallowed by design — teardown of one resource must not block others,
      // and no native detail is ever surfaced.
    }
  }
}
