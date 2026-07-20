#import <Foundation/Foundation.h>
#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// The OPTIONAL recorder plugin for the chat_ai voice session. Owns the
/// `chat_ai_openai_realtime_voice/recorder` method channel and dispatches
/// attach / beginSegment / endSegment / close to per-writer
/// [ChatAiRealtimeVoiceRecorder] instances. Command-only: no audio bytes ever
/// cross this channel — the only value returned is a finished file path.
@interface ChatAiRealtimeVoiceRecorderPlugin : NSObject <FlutterPlugin>
@end

NS_ASSUME_NONNULL_END
