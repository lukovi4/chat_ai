#import "ChatAiRealtimeVoiceRecorder.h"

#import <WebRTC/WebRTC.h>
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/LocalAudioTrack.h>

@import AVFoundation;
@import AudioToolbox;

@interface ChatAiRealtimeVoiceRecorder () <RTCAudioRenderer>
@end

@implementation ChatAiRealtimeVoiceRecorder {
  NSString *_writerId;
  BOOL _isRemote;
  NSString *_directoryPath;
  double _sampleRate;
  UInt32 _numChannels;
  UInt32 _bitRate;
  NSInteger _preRollMs;

  // The attached track (exactly one is set while rendering). Touched only on the
  // main thread (attach / detach); the render callback never reads it.
  LocalAudioTrack *_localTrack;
  RTCAudioTrack *_remoteTrack;
  BOOL _closeRequested;  // main-thread exactly-once close guard

  dispatch_queue_t _queue;

  // The bounded pre-roll window (queue-only): recent client-format PCM copies so
  // a new segment can flush the reply's onset that preceded the begin signal.
  NSMutableArray<AVAudioPCMBuffer *> *_preRoll;
  UInt64 _preRollFrames;

  // The current segment (queue-only).
  BOOL _segmentActive;   // begin received, not yet ended/finalized
  BOOL _fileOpen;        // ExtAudioFile created and configured
  BOOL _segmentFailed;   // a Core Audio error means this segment is not valid
  ExtAudioFileRef _extFile;
  AudioStreamBasicDescription _clientFormat;
  UInt64 _segmentFrames;
  NSURL *_tmpURL;
  NSURL *_finalURL;

  BOOL _closed;  // queue-only
}

- (instancetype)initWithWriterId:(NSString *)writerId
                        isRemote:(BOOL)isRemote
                   directoryPath:(NSString *)directoryPath
                      sampleRate:(NSInteger)sampleRate
                     numChannels:(NSInteger)numChannels
                         bitRate:(NSInteger)bitRate
                       preRollMs:(NSInteger)preRollMs {
  self = [super init];
  if (self) {
    _writerId = [writerId copy];
    _isRemote = isRemote;
    _directoryPath = [directoryPath copy];
    _sampleRate = (double)(sampleRate > 0 ? sampleRate : 16000);
    _numChannels = (UInt32)(numChannels > 0 ? numChannels : 1);
    _bitRate = (UInt32)(bitRate > 0 ? bitRate : 32000);
    _preRollMs = preRollMs > 0 ? preRollMs : 0;
    _queue =
        dispatch_queue_create("chat_ai.voice_recorder", DISPATCH_QUEUE_SERIAL);
    _preRoll = [NSMutableArray array];
    _preRollFrames = 0;
    _extFile = NULL;
    _closed = NO;
    _closeRequested = NO;
  }
  return self;
}

#pragma mark - Attach (main thread; light, no encoding)

- (BOOL)attachWithTrackId:(NSString *)trackId
                errorCode:(NSString *_Nullable *_Nullable)errorCode {
  if (_closeRequested) {
    if (errorCode) {
      *errorCode = @"writer_closed";
    }
    return NO;
  }
  if (_localTrack != nil || _remoteTrack != nil) {
    return YES;  // idempotent: already attached
  }

  // Ensure the app-owned output directory exists.
  NSError *dirError = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:_directoryPath
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&dirError]) {
    if (errorCode) {
      *errorCode = @"directory_unavailable";
    }
    return NO;
  }

  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (_isRemote) {
    RTCMediaStreamTrack *track = [plugin remoteTrackForId:trackId];
    if (track == nil) {
      if (errorCode) {
        *errorCode = @"track_not_found";
      }
      return NO;
    }
    if (![track isKindOfClass:[RTCAudioTrack class]]) {
      if (errorCode) {
        *errorCode = @"not_audio_track";
      }
      return NO;
    }
    _remoteTrack = (RTCAudioTrack *)track;
    [_remoteTrack addRenderer:self];
  } else {
    id<LocalTrack> local = plugin.localTracks[trackId];
    if (local == nil) {
      if (errorCode) {
        *errorCode = @"track_not_found";
      }
      return NO;
    }
    if (![local isKindOfClass:[LocalAudioTrack class]]) {
      if (errorCode) {
        *errorCode = @"not_audio_track";
      }
      return NO;
    }
    _localTrack = (LocalAudioTrack *)local;
    [_localTrack addRenderer:self];
  }
  return YES;
}

#pragma mark - RTCAudioRenderer

// Realtime audio thread: make a writer-owned copy of the PCM and hand it to the
// serial queue. NO file I/O happens here.
- (void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer {
  if (pcmBuffer == nil || pcmBuffer.frameLength == 0) {
    return;
  }
  AVAudioPCMBuffer *copy =
      [[AVAudioPCMBuffer alloc] initWithPCMFormat:pcmBuffer.format
                                    frameCapacity:pcmBuffer.frameLength];
  if (copy == nil) {
    return;
  }
  copy.frameLength = pcmBuffer.frameLength;
  const AudioBufferList *src = pcmBuffer.audioBufferList;
  AudioBufferList *dst = copy.mutableAudioBufferList;
  if (src->mNumberBuffers != dst->mNumberBuffers) {
    return;
  }
  for (UInt32 i = 0; i < src->mNumberBuffers; i++) {
    UInt32 n =
        MIN(src->mBuffers[i].mDataByteSize, dst->mBuffers[i].mDataByteSize);
    memcpy(dst->mBuffers[i].mData, src->mBuffers[i].mData, n);
    dst->mBuffers[i].mDataByteSize = n;
  }
  dispatch_async(_queue, ^{
    [self appendBuffer:copy];
  });
}

// Serial-queue only.
- (void)appendBuffer:(AVAudioPCMBuffer *)buffer {
  if (_closed) {
    return;
  }
  // 1. Lazily open the segment file from the ACTUAL client format of the first
  //    buffer, flushing the pre-roll captured before the begin signal.
  if (_segmentActive && !_fileOpen && !_segmentFailed) {
    [self openSegmentFileWithFormat:buffer.format];
  }
  // 2. Write the live buffer to the open segment.
  if (_segmentActive && _fileOpen && !_segmentFailed && _extFile != NULL) {
    UInt32 frames = buffer.frameLength;
    if (frames > 0) {
      OSStatus st = ExtAudioFileWrite(_extFile, frames, buffer.audioBufferList);
      if (st == noErr) {
        _segmentFrames += frames;
      } else {
        // A write error makes the segment untrustworthy: fail it rather than
        // publish a partial/corrupt file.
        _segmentFailed = YES;
      }
    }
  }
  // 3. Roll the pre-roll window forward for the NEXT segment.
  [self pushPreRoll:buffer];
}

- (void)pushPreRoll:(AVAudioPCMBuffer *)buffer {
  if (_preRollMs <= 0) {
    return;
  }
  [_preRoll addObject:buffer];
  _preRollFrames += buffer.frameLength;
  const UInt64 maxFrames =
      (UInt64)((double)_preRollMs * buffer.format.sampleRate / 1000.0);
  while (_preRoll.count > 1 && _preRollFrames > maxFrames) {
    AVAudioPCMBuffer *oldest = _preRoll.firstObject;
    _preRollFrames -= oldest.frameLength;
    [_preRoll removeObjectAtIndex:0];
  }
}

// Serial-queue only. Creates the ExtAudioFile as AAC-LC m4a with a real
// sample-rate/channel conversion, pins + verifies the encoder bitrate, then
// flushes the pre-roll. Every OSStatus is checked; any failure sets
// _segmentFailed so the segment is never published.
- (void)openSegmentFileWithFormat:(AVAudioFormat *)format {
  _clientFormat = *format.streamDescription;
  if (_clientFormat.mChannelsPerFrame == 0 || _clientFormat.mSampleRate <= 0) {
    _segmentFailed = YES;
    return;
  }

  AudioStreamBasicDescription fileFormat;
  memset(&fileFormat, 0, sizeof(fileFormat));
  fileFormat.mSampleRate = _sampleRate;          // 16 kHz
  fileFormat.mFormatID = kAudioFormatMPEG4AAC;   // AAC
  fileFormat.mFormatFlags = kMPEG4Object_AAC_LC; // AAC-LC
  fileFormat.mChannelsPerFrame = _numChannels;   // mono
  fileFormat.mFramesPerPacket = 1024;
  UInt32 fsize = sizeof(fileFormat);
  OSStatus st = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL,
                                       &fsize, &fileFormat);
  if (st != noErr) {
    _segmentFailed = YES;
    return;
  }

  st = ExtAudioFileCreateWithURL((__bridge CFURLRef)_tmpURL, kAudioFileM4AType,
                                 &fileFormat, NULL, kAudioFileFlags_EraseFile,
                                 &_extFile);
  if (st != noErr || _extFile == NULL) {
    _extFile = NULL;
    _segmentFailed = YES;
    return;
  }

  // ExtAudioFile converts the client PCM (any rate/layout) into the AAC file
  // format — a real resample + channel mix + encode, never a rename.
  st = ExtAudioFileSetProperty(_extFile, kExtAudioFileProperty_ClientDataFormat,
                               sizeof(_clientFormat), &_clientFormat);
  if (st != noErr) {
    [self abortOpenFile];
    return;
  }

  // Pin the encoder bitrate to the target and CONFIRM the encoder accepted it.
  AudioConverterRef converter = NULL;
  UInt32 csize = sizeof(converter);
  st = ExtAudioFileGetProperty(_extFile, kExtAudioFileProperty_AudioConverter,
                               &csize, &converter);
  if (st != noErr || converter == NULL) {
    [self abortOpenFile];
    return;
  }
  UInt32 bitRate = _bitRate;
  st = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                 sizeof(bitRate), &bitRate);
  if (st != noErr) {
    [self abortOpenFile];
    return;
  }
  UInt32 readBack = 0;
  UInt32 rbSize = sizeof(readBack);
  st = AudioConverterGetProperty(converter, kAudioConverterEncodeBitRate,
                                 &rbSize, &readBack);
  if (st != noErr || readBack != _bitRate) {
    // The encoder did not accept exactly the target bitrate — do not publish.
    [self abortOpenFile];
    return;
  }
  // Tell ExtAudioFile the converter configuration changed.
  CFArrayRef config = NULL;
  st = ExtAudioFileSetProperty(_extFile, kExtAudioFileProperty_ConverterConfig,
                               sizeof(config), &config);
  if (st != noErr) {
    [self abortOpenFile];
    return;
  }

  _fileOpen = YES;

  // Flush the pre-roll (onset lead-in) captured before the begin signal. Only
  // buffers matching the chosen client format are written.
  for (AVAudioPCMBuffer *pre in _preRoll) {
    if (memcmp(pre.format.streamDescription, &_clientFormat,
               sizeof(_clientFormat)) != 0) {
      continue;
    }
    UInt32 frames = pre.frameLength;
    if (frames > 0) {
      OSStatus wst = ExtAudioFileWrite(_extFile, frames, pre.audioBufferList);
      if (wst == noErr) {
        _segmentFrames += frames;
      } else {
        _segmentFailed = YES;
        return;
      }
    }
  }
}

- (void)abortOpenFile {
  if (_extFile != NULL) {
    ExtAudioFileDispose(_extFile);
    _extFile = NULL;
  }
  _fileOpen = NO;
  _segmentFailed = YES;
}

#pragma mark - Segments (serial queue; never blocks the caller)

- (void)beginSegment:(NSString *)segmentId
          completion:(void (^)(BOOL ok))completion {
  dispatch_async(_queue, ^{
    if (self->_closed) {
      if (completion) {
        completion(NO);
      }
      return;
    }
    // Drop any still-open previous segment's OWN temp file (defensive; the Dart
    // layer never begins while one is open, so this normally does nothing and
    // never touches a published final file).
    [self discardOpenSegmentLocked];

    // Collision-resistant unique name: even across sessions, factory instances
    // and app launches, no two files (temp or final) can share a path, so a
    // finished file can never be overwritten by a per-session counter reset.
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *base = [NSString
        stringWithFormat:@"rtvoice_%@_%@", self->_isRemote ? @"assistant"
                                                           : @"user",
                         uuid];
    NSString *finalName = [base stringByAppendingPathExtension:@"m4a"];
    NSString *tmpName = [finalName stringByAppendingPathExtension:@"part"];
    self->_finalURL = [NSURL
        fileURLWithPath:[self->_directoryPath
                            stringByAppendingPathComponent:finalName]];
    self->_tmpURL = [NSURL
        fileURLWithPath:[self->_directoryPath
                            stringByAppendingPathComponent:tmpName]];
    // Only ever remove our OWN not-yet-created temp (never a final file).
    [[NSFileManager defaultManager] removeItemAtURL:self->_tmpURL error:nil];

    self->_segmentActive = YES;
    self->_fileOpen = NO;
    self->_segmentFailed = NO;
    self->_segmentFrames = 0;
    self->_extFile = NULL;
    if (completion) {
      completion(YES);
    }
  });
}

- (void)endSegment:(NSString *)segmentId
        completion:(void (^)(NSDictionary<NSString *, id> *result))completion {
  dispatch_async(_queue, ^{
    NSDictionary<NSString *, id> *result = [self finalizeSegmentLocked];
    if (completion) {
      completion(result);
    }
  });
}

// Serial-queue only.
- (NSDictionary<NSString *, id> *)finalizeSegmentLocked {
  if (_closed || !_segmentActive) {
    return @{@"ok" : @NO};
  }

  // Flush + close the encoder file so every frame is on disk; check dispose.
  BOOL disposeOk = YES;
  if (_fileOpen && _extFile != NULL) {
    OSStatus st = ExtAudioFileDispose(_extFile);
    disposeOk = (st == noErr);
  }
  _extFile = NULL;
  _fileOpen = NO;
  _segmentActive = NO;

  // A fresh pre-roll window for the next reply (never bleeds this reply in).
  [_preRoll removeAllObjects];
  _preRollFrames = 0;

  NSURL *tmp = _tmpURL;
  NSURL *final = _finalURL;
  _tmpURL = nil;
  _finalURL = nil;

  NSFileManager *fm = [NSFileManager defaultManager];
  if (_segmentFailed || !disposeOk || _segmentFrames == 0 || tmp == nil) {
    if (tmp != nil) {
      [fm removeItemAtURL:tmp error:nil];
    }
    return @{@"ok" : @NO};
  }

  // Validate the actual on-disk file — never trust length alone.
  if (![self validateFileAtURL:tmp]) {
    [fm removeItemAtURL:tmp error:nil];
    return @{@"ok" : @NO};
  }

  // Promote the validated temp to its unique final path with a NO-OVERWRITE
  // move. moveItemAtURL fails if the destination exists, so a finished file is
  // never deleted or replaced; on any move error we drop only our own temp.
  if (final == nil) {
    [fm removeItemAtURL:tmp error:nil];
    return @{@"ok" : @NO};
  }
  NSError *moveErr = nil;
  if (![fm moveItemAtURL:tmp toURL:final error:&moveErr]) {
    [fm removeItemAtURL:tmp error:nil];
    return @{@"ok" : @NO};
  }
  return @{@"ok" : @YES, @"filePath" : final.path};
}

// Confirms the finished file opens and is AAC-LC / M4A / 16 kHz / mono with a
// non-zero number of audio frames. Uses only AVFoundation (no third-party
// dependency, no hand-written M4A parser).
- (BOOL)validateFileAtURL:(NSURL *)url {
  NSError *readError = nil;
  AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&readError];
  if (file == nil || readError != nil) {
    return NO;
  }
  const AudioStreamBasicDescription *asbd =
      file.fileFormat.streamDescription;
  if (asbd == NULL) {
    return NO;
  }
  if (asbd->mFormatID != kAudioFormatMPEG4AAC) {
    return NO;
  }
  if ((UInt32)llround(asbd->mSampleRate) != (UInt32)llround(_sampleRate)) {
    return NO;
  }
  if (asbd->mChannelsPerFrame != _numChannels) {
    return NO;
  }
  if (file.length <= 0) {
    return NO;
  }
  return YES;
}

// Queue-only: dispose and delete an unfinalized open segment's OWN temp file.
// Never touches a published final file.
- (void)discardOpenSegmentLocked {
  if (_fileOpen && _extFile != NULL) {
    ExtAudioFileDispose(_extFile);
    _extFile = NULL;
  }
  _fileOpen = NO;
  if (_segmentActive && _tmpURL != nil) {
    [[NSFileManager defaultManager] removeItemAtURL:_tmpURL error:nil];
  }
  _segmentActive = NO;
  _tmpURL = nil;
  _finalURL = nil;
}

#pragma mark - Teardown

- (void)closeWithCompletion:(void (^)(void))completion {
  // Exactly-once on the main thread; remove the renderer FIRST so no new buffer
  // is scheduled.
  if (_closeRequested) {
    if (completion) {
      completion();
    }
    return;
  }
  _closeRequested = YES;
  if (_remoteTrack != nil) {
    [_remoteTrack removeRenderer:self];
    _remoteTrack = nil;
  }
  if (_localTrack != nil) {
    [_localTrack removeRenderer:self];
    _localTrack = nil;
  }
  dispatch_async(_queue, ^{
    self->_closed = YES;
    [self discardOpenSegmentLocked];
    [self->_preRoll removeAllObjects];
    self->_preRollFrames = 0;
    if (completion) {
      completion();
    }
  });
}

@end
