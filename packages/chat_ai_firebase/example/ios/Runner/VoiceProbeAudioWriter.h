#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// App-local, iOS-native audio writer for the Increment-0 voice feasibility
/// spike. Attaches to one existing WebRTC audio track (local or remote) as a
/// public `RTCAudioRenderer` (`addRenderer:` / `removeRenderer:`) and writes an
/// audio-only WAV file entirely on the iOS side.
///
/// - No PCM/AVAudioPCMBuffer/bytes ever cross the Flutter channel.
/// - No second microphone engine; the renderer observes the existing track.
/// - No video, no `FlutterRTCMediaRecorder` (its writer is video-first).
///
/// start/finalize/close are idempotent and exactly-once per instance. Failures
/// are reported only as short, stable codes — never a path, track id or native
/// description.
@interface VoiceProbeAudioWriter : NSObject

- (instancetype)initWithWriterId:(NSString *)writerId isRemote:(BOOL)isRemote;

/// Resolves the track on the shared `FlutterWebRTCPlugin` singleton, verifies
/// it is an audio track and attaches this writer as its `RTCAudioRenderer`.
/// Returns NO and fills a stable [errorCode] (`track_not_found` /
/// `not_audio_track`) on failure.
- (BOOL)startWithTrackId:(NSString *)trackId
               errorCode:(NSString *_Nullable *_Nullable)errorCode;

/// Removes the renderer, drains accepted buffers, closes and validates the
/// file, and returns a minimal, content-free diagnostic dictionary. Keys:
/// `ok` (bool), `durationMs` (int), `callbackCount` (int),
/// `writtenFrames` (int), `status` (stable string: ok / noCallbacks /
/// noFrames / fileFailed / validationFailed / writerClosed). No path /
/// OSStatus / native message / audio is ever included. Memoized.
- (NSDictionary<NSString *, id> *)finalizeAndDiagnose;

/// Plays the finalized file by handle. Returns NO on failure.
- (BOOL)play;

/// Full teardown: removes the renderer, stops playback, disposes the file
/// writer and deletes the file. Idempotent.
- (void)close;

@end

NS_ASSUME_NONNULL_END
