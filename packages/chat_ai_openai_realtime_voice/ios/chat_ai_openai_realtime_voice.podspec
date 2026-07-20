#
# The minimal iOS plugin for chat_ai_openai_realtime_voice: the OPTIONAL
# native audio recorder. It attaches to the EXISTING flutter_webrtc local /
# remote audio tracks as a public RTCAudioRenderer and writes one AAC-LC `.m4a`
# file per reply entirely on the iOS side. No PCM/audio bytes ever cross the
# Flutter method channel — only commands and safe scalar metadata.
#
# Recording is iOS-only in this increment. When recording is disabled the
# plugin does nothing (its channel is simply never called).
#
Pod::Spec.new do |s|
  s.name             = 'chat_ai_openai_realtime_voice'
  s.version          = '0.1.0'
  s.summary          = 'Optional native audio recorder for the chat_ai voice session (iOS).'
  s.description      = <<-DESC
Writes one AAC-LC .m4a file per spoken reply by attaching to the existing
flutter_webrtc audio tracks as an RTCAudioRenderer. Audio never crosses the
Flutter channel.
                       DESC
  s.homepage         = 'https://example.com/chat_ai_openai_realtime_voice'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'chat_ai' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  # The recorder resolves tracks on the shared FlutterWebRTCPlugin singleton and
  # uses the WebRTC-SDK RTCAudioRenderer / RTCAudioTrack headers. Pinned to the
  # same stack the voice package already depends on.
  s.dependency 'flutter_webrtc'
  s.dependency 'WebRTC-SDK'
  s.ios.deployment_target = '13.0'
  s.static_framework = true
  s.frameworks = 'AVFoundation', 'AudioToolbox'
  s.libraries = 'c++'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
