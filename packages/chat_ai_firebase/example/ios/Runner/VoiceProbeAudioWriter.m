#import "VoiceProbeAudioWriter.h"

#import <WebRTC/WebRTC.h>
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/LocalAudioTrack.h>

@import AVFoundation;
@import AudioToolbox;

@interface VoiceProbeAudioWriter () <RTCAudioRenderer>
@end

@implementation VoiceProbeAudioWriter {
  NSString *_writerId;
  BOOL _isRemote;

  // The attached track (exactly one of these is set while rendering) so the
  // renderer can be removed symmetrically on finalize/close.
  LocalAudioTrack *_localTrack;
  RTCAudioTrack *_remoteTrack;

  dispatch_queue_t _queue;

  ExtAudioFileRef _extFile;
  BOOL _fileOpen;
  BOOL _everFileOpened;
  BOOL _fileFailed;
  AudioStreamBasicDescription _clientFormat;
  UInt64 _totalFrames;

  // Aggregated, content-free diagnostics.
  NSUInteger _callbackCount;
  NSUInteger _writeCount;

  NSURL *_url;
  AVAudioPlayer *_player;

  BOOL _started;
  BOOL _finalized;
  BOOL _valid;
  NSInteger _durationMs;
  BOOL _closed;
  NSDictionary<NSString *, id> *_cachedDiagnostics;
}

- (instancetype)initWithWriterId:(NSString *)writerId isRemote:(BOOL)isRemote {
  self = [super init];
  if (self) {
    _writerId = [writerId copy];
    _isRemote = isRemote;
    _queue = dispatch_queue_create("voice_probe.audio_writer", DISPATCH_QUEUE_SERIAL);
    _extFile = NULL;
    _fileOpen = NO;
    _everFileOpened = NO;
    _fileFailed = NO;
    _totalFrames = 0;
    _callbackCount = 0;
    _writeCount = 0;
    _started = NO;
    _finalized = NO;
    _valid = NO;
    _durationMs = 0;
    _closed = NO;
    NSString *name =
        [NSString stringWithFormat:@"voice_probe_%@_%@.wav",
                                   isRemote ? @"assistant" : @"user", writerId];
    _url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                      stringByAppendingPathComponent:name]];
  }
  return self;
}

- (BOOL)startWithTrackId:(NSString *)trackId
               errorCode:(NSString *_Nullable *_Nullable)errorCode {
  if (_closed) {
    // A closed writer can never be revived — controlled failure, no false YES.
    if (errorCode) {
      *errorCode = @"writer_closed";
    }
    return NO;
  }
  if (_started) {
    // Idempotent: an already-armed writer stays armed.
    return YES;
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
  }

  [[NSFileManager defaultManager] removeItemAtURL:_url error:nil];

  // Attach as the track's audio renderer — track-level PCM delivery.
  if (_remoteTrack != nil) {
    [_remoteTrack addRenderer:self];
  } else {
    [_localTrack addRenderer:self];
  }
  _started = YES;
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
    UInt32 n = MIN(src->mBuffers[i].mDataByteSize, dst->mBuffers[i].mDataByteSize);
    memcpy(dst->mBuffers[i].mData, src->mBuffers[i].mData, n);
    dst->mBuffers[i].mDataByteSize = n;
  }
  dispatch_async(_queue, ^{
    [self appendBuffer:copy];
  });
}

// Serial-queue only.
- (void)appendBuffer:(AVAudioPCMBuffer *)buffer {
  // Count every delivered buffer BEFORE any early-out so `noCallbacks` is
  // distinguishable from `noFrames`.
  _callbackCount++;
  if (_finalized || _closed) {
    return;
  }

  if (!_fileOpen) {
    // Initialize the file from the ACTUAL client format of the first buffer.
    _clientFormat = *buffer.format.streamDescription;
    if (_clientFormat.mChannelsPerFrame == 0 || _clientFormat.mSampleRate <= 0) {
      _fileFailed = YES;
      return;
    }
    // Interleaved 16-bit LinearPCM WAV; ExtAudioFile converts the client
    // format (interleaved OR non-interleaved, int OR float) into it.
    AudioStreamBasicDescription fileFormat;
    memset(&fileFormat, 0, sizeof(fileFormat));
    fileFormat.mSampleRate = _clientFormat.mSampleRate;
    fileFormat.mFormatID = kAudioFormatLinearPCM;
    fileFormat.mFormatFlags =
        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fileFormat.mBitsPerChannel = 16;
    fileFormat.mChannelsPerFrame = _clientFormat.mChannelsPerFrame;
    fileFormat.mFramesPerPacket = 1;
    fileFormat.mBytesPerFrame = 2 * _clientFormat.mChannelsPerFrame;
    fileFormat.mBytesPerPacket = 2 * _clientFormat.mChannelsPerFrame;

    OSStatus st = ExtAudioFileCreateWithURL(
        (__bridge CFURLRef)_url, kAudioFileWAVEType, &fileFormat, NULL,
        kAudioFileFlags_EraseFile, &_extFile);
    if (st != noErr || _extFile == NULL) {
      _extFile = NULL;
      _fileFailed = YES;
      return;
    }
    st = ExtAudioFileSetProperty(_extFile,
                                 kExtAudioFileProperty_ClientDataFormat,
                                 sizeof(_clientFormat), &_clientFormat);
    if (st != noErr) {
      ExtAudioFileDispose(_extFile);
      _extFile = NULL;
      _fileFailed = YES;
      return;
    }
    _fileOpen = YES;
    _everFileOpened = YES;
  }

  const UInt32 frames = buffer.frameLength;
  if (frames > 0 && _extFile != NULL) {
    if (ExtAudioFileWrite(_extFile, frames, buffer.audioBufferList) == noErr) {
      _totalFrames += frames;
      _writeCount++;
    }
  }
}

#pragma mark - Lifecycle

- (void)detachRenderer {
  if (_remoteTrack != nil) {
    [_remoteTrack removeRenderer:self];
    _remoteTrack = nil;
  }
  if (_localTrack != nil) {
    [_localTrack removeRenderer:self];
    _localTrack = nil;
  }
}

- (NSDictionary<NSString *, id> *)finalizeAndDiagnose {
  // Read the cross-queue flags on the queue for correct synchronization.
  __block BOOL wasClosed = NO;
  __block BOOL wasFinalized = NO;
  dispatch_sync(_queue, ^{
    wasClosed = self->_closed;
    wasFinalized = self->_finalized;
  });
  if (wasClosed) {
    return [self diagnosticsOk:NO status:@"writerClosed"];
  }
  if (wasFinalized && _cachedDiagnostics != nil) {
    return _cachedDiagnostics;  // memoized
  }

  // 1. Remove the renderer FIRST so no new PCM buffer is ever scheduled.
  [self detachRenderer];

  // 2. Drain already-accepted / in-flight buffers (they run before this block
  //    on the serial queue and still see _finalized == NO, so every buffer
  //    accepted before finalize is written). ONLY THEN mark finalized and
  //    close the file — no write can happen after ExtAudioFileDispose.
  dispatch_sync(_queue, ^{
    self->_finalized = YES;
    if (self->_fileOpen && self->_extFile != NULL) {
      ExtAudioFileDispose(self->_extFile);
      self->_extFile = NULL;
      self->_fileOpen = NO;
    }
  });

  // Compute the coarse status from counters, then validate the file.
  NSString *status;
  BOOL ok = NO;
  if (_callbackCount == 0) {
    status = @"noCallbacks";
  } else if (_fileFailed && !_everFileOpened) {
    status = @"fileFailed";
  } else if (_totalFrames == 0) {
    status = @"noFrames";
  } else {
    NSError *err = nil;
    AVAudioFile *readFile = [[AVAudioFile alloc] initForReading:_url error:&err];
    if (readFile == nil || err != nil) {
      status = @"validationFailed";
    } else {
      AVAudioFramePosition length = readFile.length;
      double sampleRate = readFile.fileFormat.sampleRate;
      NSInteger ms = (sampleRate > 0)
                         ? (NSInteger)((double)length / sampleRate * 1000.0)
                         : 0;
      if (length <= 0 || sampleRate <= 0 || ms <= 0) {
        status = @"validationFailed";
      } else {
        ok = YES;
        status = @"ok";
        _valid = YES;
        _durationMs = ms;
      }
    }
  }

  _cachedDiagnostics = [self diagnosticsOk:ok status:status];
  return _cachedDiagnostics;
}

- (NSDictionary<NSString *, id> *)diagnosticsOk:(BOOL)ok
                                          status:(NSString *)status {
  return @{
    @"ok" : @(ok),
    @"durationMs" : @(_durationMs),
    @"callbackCount" : @((NSInteger)_callbackCount),
    @"writtenFrames" : @((NSInteger)_totalFrames),
    @"status" : status ?: @"unknown",
  };
}

- (BOOL)play {
  if (!_finalized || !_valid || _closed) {
    return NO;
  }
  // Ensure the route allows playback after the WebRTC session is gone.
  AVAudioSession *session = [AVAudioSession sharedInstance];
  [session setCategory:AVAudioSessionCategoryPlayback error:nil];
  [session setActive:YES error:nil];

  NSError *err = nil;
  _player = [[AVAudioPlayer alloc] initWithContentsOfURL:_url error:&err];
  if (_player == nil || err != nil) {
    return NO;
  }
  [_player prepareToPlay];
  return [_player play];
}

- (void)close {
  __block BOOL wasClosed = NO;
  dispatch_sync(_queue, ^{
    wasClosed = self->_closed;
  });
  if (wasClosed) {
    return;
  }
  // Remove the renderer first so no new buffer is scheduled, then drain and
  // dispose on the queue while flipping _closed under the same serialization.
  [self detachRenderer];
  dispatch_sync(_queue, ^{
    self->_closed = YES;
    if (self->_extFile != NULL) {
      ExtAudioFileDispose(self->_extFile);
      self->_extFile = NULL;
      self->_fileOpen = NO;
    }
  });
  if (_player != nil) {
    [_player stop];
    _player = nil;
  }
  [[NSFileManager defaultManager] removeItemAtURL:_url error:nil];
}

@end
