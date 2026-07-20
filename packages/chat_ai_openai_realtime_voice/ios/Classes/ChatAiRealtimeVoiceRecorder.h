#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The OPTIONAL iOS-native audio recorder for one side (local user OR remote
/// assistant) of the chat_ai voice session.
///
/// It attaches to ONE existing flutter_webrtc audio track as a public
/// `RTCAudioRenderer` (`addRenderer:` / `removeRenderer:`) and writes one AAC-LC
/// `.m4a` file PER REPLY entirely on the iOS side, with a bounded pre-roll so a
/// reply's onset is not clipped by event-delivery latency. The output format is
/// fixed to the record_transcribe speech profile: m4a / AAC-LC / 16 kHz / mono /
/// 32 kbit/s, with a real sample-rate + channel conversion and AAC encoding via
/// ExtAudioFile (never a rename). Every Core Audio OSStatus is checked and the
/// finished file is validated (format / rate / channels / non-zero frames)
/// before it is published.
///
/// Segment boundaries are EVENT-DRIVEN by the Dart layer (a validated
/// speech_started → speech_stopped pair for the user; output_audio_buffer
/// started/stopped for the assistant). This writer does NOT map OpenAI
/// `audio_*_ms` to a device PCM offset — no such mapping exists over
/// flutter_webrtc — so no sample-accurate boundary is claimed.
///
/// - No PCM / AVAudioPCMBuffer / bytes ever cross the Flutter channel.
/// - No second microphone engine; the renderer observes the existing track.
/// - A finished, validated file stays in the app-owned directory; the package
///   NEVER deletes or overwrites it afterwards. An unfinished / invalid
///   temporary file (only ever this writer's own) is deleted.
/// - Every file gets a collision-resistant unique name; a finished file is
///   never replaced.
///
/// beginSegment / endSegment / close run their file work on a private serial
/// queue and report back via a completion block — they NEVER block the calling
/// (main) thread. attach / beginSegment / endSegment / close are idempotent and
/// exactly-once per instance. Failures are reported only as short stable codes
/// or a non-throwing `{ok:NO}` result — never a path, track id or native
/// description.
@interface ChatAiRealtimeVoiceRecorder : NSObject

- (instancetype)initWithWriterId:(NSString *)writerId
                        isRemote:(BOOL)isRemote
                   directoryPath:(NSString *)directoryPath
                      sampleRate:(NSInteger)sampleRate
                     numChannels:(NSInteger)numChannels
                         bitRate:(NSInteger)bitRate
                       preRollMs:(NSInteger)preRollMs;

/// Resolves the track on the shared `FlutterWebRTCPlugin` singleton, verifies it
/// is an audio track, ensures the output directory exists and attaches this
/// recorder as the track's `RTCAudioRenderer`. Synchronous and light (no file
/// encoding); returns NO and fills a stable [errorCode] on failure.
- (BOOL)attachWithTrackId:(NSString *)trackId
                errorCode:(NSString *_Nullable *_Nullable)errorCode;

/// Opens a new per-reply segment. Runs on the serial queue; [completion] is
/// invoked (on the queue) with whether the segment armed.
- (void)beginSegment:(NSString *)segmentId
          completion:(void (^)(BOOL ok))completion;

/// Finalizes the current segment: flush + dispose the encoder, validate the
/// format/rate/channels/frames, and — only if valid — move it (no overwrite)
/// into the app-owned directory. Runs on the serial queue; [completion] is
/// invoked with `{ok: BOOL, filePath: NSString*}` (`filePath` only when ok).
/// Never throws; an invalid / empty / colliding temp file is deleted.
- (void)endSegment:(NSString *)segmentId
        completion:(void (^)(NSDictionary<NSString *, id> *result))completion;

/// Full teardown: removes the renderer, drops any open (unfinalized) segment's
/// temporary file and the pre-roll, releases resources. Idempotent;
/// [completion] is invoked when done.
- (void)closeWithCompletion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
