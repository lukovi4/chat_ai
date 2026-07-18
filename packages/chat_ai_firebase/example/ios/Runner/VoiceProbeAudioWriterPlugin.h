#import <Foundation/Foundation.h>
#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// App-local Flutter plugin for the Increment-0 voice spike. Owns the
/// `voice_probe/audio_writer` method channel and dispatches start/finalize/
/// play/close to per-writer [VoiceProbeAudioWriter] instances. Command-only:
/// no audio bytes ever cross this channel.
@interface VoiceProbeAudioWriterPlugin : NSObject <FlutterPlugin>
@end

NS_ASSUME_NONNULL_END
