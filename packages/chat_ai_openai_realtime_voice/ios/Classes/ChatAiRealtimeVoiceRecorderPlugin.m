#import "ChatAiRealtimeVoiceRecorderPlugin.h"
#import "ChatAiRealtimeVoiceRecorder.h"

@implementation ChatAiRealtimeVoiceRecorderPlugin {
  NSMutableDictionary<NSString *, ChatAiRealtimeVoiceRecorder *> *_writers;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel = [FlutterMethodChannel
      methodChannelWithName:@"chat_ai_openai_realtime_voice/recorder"
            binaryMessenger:[registrar messenger]];
  ChatAiRealtimeVoiceRecorderPlugin *instance =
      [[ChatAiRealtimeVoiceRecorderPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _writers = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  NSDictionary *args =
      [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;
  NSString *writerId = args[@"writerId"];
  if (![writerId isKindOfClass:[NSString class]]) {
    result([FlutterError errorWithCode:@"bad_args" message:nil details:nil]);
    return;
  }

  if ([@"attach" isEqualToString:call.method]) {
    NSString *trackId = args[@"trackId"];
    NSString *directoryPath = args[@"directoryPath"];
    if (![trackId isKindOfClass:[NSString class]] ||
        ![directoryPath isKindOfClass:[NSString class]]) {
      result([FlutterError errorWithCode:@"bad_args" message:nil details:nil]);
      return;
    }
    BOOL isRemote = [args[@"isRemote"] boolValue];
    ChatAiRealtimeVoiceRecorder *writer = _writers[writerId];
    if (writer == nil) {
      writer = [[ChatAiRealtimeVoiceRecorder alloc]
          initWithWriterId:writerId
                  isRemote:isRemote
             directoryPath:directoryPath
                sampleRate:[args[@"sampleRate"] integerValue]
               numChannels:[args[@"numChannels"] integerValue]
                   bitRate:[args[@"bitRate"] integerValue]
                 preRollMs:[args[@"preRollMs"] integerValue]];
      _writers[writerId] = writer;
    }
    NSString *code = nil;
    if ([writer attachWithTrackId:trackId errorCode:&code]) {
      result(nil);
    } else {
      result([FlutterError errorWithCode:(code ?: @"attach_failed")
                                 message:nil
                                 details:nil]);
    }
  } else if ([@"beginSegment" isEqualToString:call.method]) {
    NSString *segmentId = args[@"segmentId"];
    ChatAiRealtimeVoiceRecorder *writer = _writers[writerId];
    if (writer == nil || ![segmentId isKindOfClass:[NSString class]]) {
      result([FlutterError errorWithCode:@"bad_args" message:nil details:nil]);
      return;
    }
    // Runs on the writer's serial queue; the result is delivered back on the
    // main queue exactly once. The main thread is never blocked.
    [writer beginSegment:segmentId
              completion:^(BOOL ok) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  if (ok) {
                    result(nil);
                  } else {
                    result([FlutterError errorWithCode:@"begin_failed"
                                               message:nil
                                               details:nil]);
                  }
                });
              }];
  } else if ([@"endSegment" isEqualToString:call.method]) {
    NSString *segmentId = args[@"segmentId"];
    ChatAiRealtimeVoiceRecorder *writer = _writers[writerId];
    if (writer == nil || ![segmentId isKindOfClass:[NSString class]]) {
      // A missing writer is a safe, non-throwing failure result — never a raw
      // error, so the coordinator emits exactly one coarse failure.
      result(@{@"ok" : @NO});
      return;
    }
    // The finalize (dispose / validate / move) runs on the writer queue; the
    // main thread is never blocked. The result carries ONLY {ok, filePath?} —
    // safe scalar metadata, never audio, counts, OSStatus or a native message.
    [writer endSegment:segmentId
            completion:^(NSDictionary<NSString *, id> *res) {
              dispatch_async(dispatch_get_main_queue(), ^{
                result(res);
              });
            }];
  } else if ([@"close" isEqualToString:call.method]) {
    ChatAiRealtimeVoiceRecorder *writer = _writers[writerId];
    [_writers removeObjectForKey:writerId];
    if (writer == nil) {
      result(nil);
      return;
    }
    [writer closeWithCompletion:^{
      dispatch_async(dispatch_get_main_queue(), ^{
        result(nil);
      });
    }];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end
