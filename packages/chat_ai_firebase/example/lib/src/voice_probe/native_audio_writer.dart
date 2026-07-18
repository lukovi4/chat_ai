// Dart facade over the app-local iOS native audio writer (Increment-0 spike).
//
// This channel carries COMMANDS ONLY — a writer id, a local/remote flag and a
// track id. PCM, AVAudioPCMBuffers, audio bytes or base64 NEVER cross it: the
// native side attaches to the track as a public RTCAudioRenderer and writes the
// file entirely on the iOS side. Playback is driven by the opaque writer id,
// never by a path.
//
// Every failure surfaced to the rest of the probe is a stable
// [VoiceProbeErrorCode] with no native description, track id or path.
import 'dart:async';

import 'package:flutter/services.dart';

import 'probe_state.dart';

/// The one method channel name; kept in sync with the native plugin.
const String kVoiceProbeWriterChannel = 'voice_probe/audio_writer';

/// Thrown by a writer operation. Carries ONLY a coarse [code] — never the
/// native message, track id, path or status.
class VoiceProbeWriterException implements Exception {
  const VoiceProbeWriterException(this.code);

  final VoiceProbeErrorCode code;

  @override
  String toString() => 'VoiceProbeWriterException(${code.name})';
}

/// The result of finalizing one writer: whether a valid artifact was produced,
/// the (opaque) artifact if so, and minimal content-free diagnostics either
/// way. Finalize NEVER throws for an invalid result — the diagnostics carry the
/// coarse reason so both writers can be finalized independently and reported.
class WriterFinalizeResult {
  const WriterFinalizeResult({
    required this.ok,
    required this.diagnostics,
    this.artifact,
  });

  final bool ok;
  final VoiceProbeArtifact? artifact;
  final WriterDiagnostics diagnostics;
}

/// Creates [NativeAudioWriter]s over one shared method channel. The channel is
/// injectable so tests can assert exactly which commands (and no audio bytes)
/// cross it.
class NativeAudioWriterFactory {
  NativeAudioWriterFactory({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kVoiceProbeWriterChannel);

  final MethodChannel _channel;
  int _seq = 0;

  /// One writer for a local (user) or remote (assistant) audio track. The
  /// [writerId] is unique per process so a second probe turn can never collide
  /// with a not-yet-released native writer.
  NativeAudioWriter create({required bool isRemote}) {
    final id = '${isRemote ? 'assistant' : 'user'}-${_seq++}';
    return NativeAudioWriter._(_channel, id, isRemote);
  }
}

/// One native writer instance. start/finalize/close are idempotent and
/// exactly-once on the Dart side too (the native side is idempotent as well).
class NativeAudioWriter {
  NativeAudioWriter._(this._channel, this.writerId, this.isRemote);

  final MethodChannel _channel;

  /// Opaque per-process writer id; also the playback handle. Never a path.
  final String writerId;

  /// Local user capture (false) vs remote assistant track (true).
  final bool isRemote;

  bool _started = false;
  bool _closed = false;
  Future<WriterFinalizeResult>? _finalizing;

  /// Arms the writer: looks the track up on the shared flutter_webrtc plugin
  /// singleton, verifies it is an audio track and attaches the renderer. Must be
  /// called BEFORE the local track is enabled so no early buffer is lost.
  ///
  /// [trackId] is the LOCAL track id when [isRemote] is false and the REMOTE
  /// track id when true — the writer never receives the other side's id. The
  /// native side resolves a local track from the plugin's local-track table
  /// (peer-connection-independent), so no peer-connection id is needed.
  Future<void> start({required String trackId}) async {
    if (_started || _closed) return;
    _started = true;
    try {
      await _channel.invokeMethod<void>('start', <String, Object?>{
        'writerId': writerId,
        'isRemote': isRemote,
        'trackId': trackId,
      });
    } on PlatformException catch (e) {
      throw VoiceProbeWriterException(_map(e.code));
    }
  }

  /// Stops accepting buffers, detaches the renderer, closes and validates the file,
  /// and returns a [WriterFinalizeResult] with an (opaque) artifact when valid
  /// and minimal diagnostics either way. NEVER throws for an invalid result.
  /// Memoized: concurrent/repeat calls await the same finalization.
  Future<WriterFinalizeResult> finalize() => _finalizing ??= _finalizeOnce();

  Future<WriterFinalizeResult> _finalizeOnce() async {
    Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<Object?, Object?>(
        'finalize',
        <String, Object?>{'writerId': writerId},
      );
    } on PlatformException {
      // Even a platform failure is a diagnosable, non-throwing outcome.
      return const WriterFinalizeResult(
        ok: false,
        diagnostics: WriterDiagnostics(
          callbackCount: 0,
          writtenFrames: 0,
          status: WriterStatus.unknown,
        ),
      );
    }
    final ok = result?['ok'] == true;
    final durationMs = result?['durationMs'];
    final callbackCount = result?['callbackCount'];
    final writtenFrames = result?['writtenFrames'];
    final diagnostics = WriterDiagnostics(
      callbackCount: callbackCount is int ? callbackCount : 0,
      writtenFrames: writtenFrames is int ? writtenFrames : 0,
      status: _parseStatus(result?['status']),
    );
    if (ok && durationMs is int && durationMs > 0) {
      return WriterFinalizeResult(
        ok: true,
        diagnostics: diagnostics,
        artifact: VoiceProbeArtifact(handle: writerId, durationMs: durationMs),
      );
    }
    return WriterFinalizeResult(ok: false, diagnostics: diagnostics);
  }

  static WriterStatus _parseStatus(Object? raw) {
    switch (raw) {
      case 'ok':
        return WriterStatus.ok;
      case 'noCallbacks':
        return WriterStatus.noCallbacks;
      case 'noFrames':
        return WriterStatus.noFrames;
      case 'fileFailed':
        return WriterStatus.fileFailed;
      case 'validationFailed':
        return WriterStatus.validationFailed;
      case 'writerClosed':
        return WriterStatus.writerClosed;
      default:
        return WriterStatus.unknown;
    }
  }

  /// Plays the finalized file by opaque handle. Best-effort; a failure is a
  /// stable code with no detail.
  Future<void> play() async {
    try {
      await _channel.invokeMethod<void>('play', <String, Object?>{
        'writerId': writerId,
      });
    } on PlatformException catch (e) {
      throw VoiceProbeWriterException(_map(e.code));
    }
  }

  /// Releases the renderer, file writer and any player. Idempotent / exactly-once;
  /// a native failure never propagates (cleanup must not throw).
  Future<void> close() async {
    if (_closed) return;
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

  /// Maps any native error code to a coarse probe code. The native side is
  /// contracted to send only short stable codes; anything else is `writerFailed`.
  static VoiceProbeErrorCode _map(String nativeCode) {
    switch (nativeCode) {
      case 'track_not_found':
      case 'not_audio_track':
        return VoiceProbeErrorCode.writerFailed;
      default:
        return VoiceProbeErrorCode.writerFailed;
    }
  }
}
