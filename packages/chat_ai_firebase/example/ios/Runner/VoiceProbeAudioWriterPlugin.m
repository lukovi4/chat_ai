#import "VoiceProbeAudioWriterPlugin.h"
#import "VoiceProbeAudioWriter.h"

@implementation VoiceProbeAudioWriterPlugin {
  NSMutableDictionary<NSString *, VoiceProbeAudioWriter *> *_writers;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"voice_probe/audio_writer"
                                  binaryMessenger:[registrar messenger]];
  VoiceProbeAudioWriterPlugin *instance =
      [[VoiceProbeAudioWriterPlugin alloc] init];
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

  if ([@"start" isEqualToString:call.method]) {
    NSString *trackId = args[@"trackId"];
    if (![trackId isKindOfClass:[NSString class]]) {
      result([FlutterError errorWithCode:@"bad_args" message:nil details:nil]);
      return;
    }
    BOOL isRemote = [args[@"isRemote"] boolValue];
    VoiceProbeAudioWriter *writer = _writers[writerId];
    if (writer == nil) {
      writer = [[VoiceProbeAudioWriter alloc] initWithWriterId:writerId
                                                      isRemote:isRemote];
      _writers[writerId] = writer;
    }
    NSString *code = nil;
    if ([writer startWithTrackId:trackId errorCode:&code]) {
      result(nil);
    } else {
      result([FlutterError errorWithCode:(code ?: @"writer_failed")
                                 message:nil
                                 details:nil]);
    }
  } else if ([@"finalize" isEqualToString:call.method]) {
    VoiceProbeAudioWriter *writer = _writers[writerId];
    if (writer == nil) {
      // A missing writer is a safe, diagnosable result — never a raw error.
      result(@{
        @"ok" : @NO,
        @"durationMs" : @0,
        @"callbackCount" : @0,
        @"writtenFrames" : @0,
        @"status" : @"writerClosed",
      });
      return;
    }
    result([writer finalizeAndDiagnose]);
  } else if ([@"play" isEqualToString:call.method]) {
    VoiceProbeAudioWriter *writer = _writers[writerId];
    if (writer != nil && [writer play]) {
      result(nil);
    } else {
      result([FlutterError errorWithCode:@"writer_failed"
                                 message:nil
                                 details:nil]);
    }
  } else if ([@"close" isEqualToString:call.method]) {
    VoiceProbeAudioWriter *writer = _writers[writerId];
    [writer close];
    [_writers removeObjectForKey:writerId];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end
