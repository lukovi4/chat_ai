/// chat_ai_openai_realtime_voice — an OPTIONAL speech-to-speech voice session
/// for `chat_ai`.
///
/// It is NOT a `ChatBackend` and it does not use `ChatSession`. It provides one
/// stateful session over a direct device → OpenAI Realtime WebRTC call:
/// ephemeral secret from the app's `ClientSecretProvider`, one microphone
/// track, one remote assistant audio track, one `oai-events` data channel, the
/// official `POST /v1/realtime/calls` signaling, server-side semantic VAD and
/// automatic user barge-in. No retry, no reconnect, no session renewal.
///
/// The public surface is exactly five declarations: the session
/// ([OpenAIRealtimeVoiceSession]), its [OpenAIRealtimeVoiceMode], and the
/// coarse [OpenAIRealtimeVoicePhase] / [OpenAIRealtimeVoiceState] /
/// [OpenAIRealtimeVoiceFailure] surface. The WebRTC transport, signaling,
/// session-update builder, cancellation and release helpers are
/// package-internal and never exported.
///
/// This increment does NOT implement tools, transcripts, recording, playback,
/// persistence or UI. If `botProfile.tools` is non-empty the session
/// constructor throws synchronously (tools are a later increment).
library;

export 'src/voice_session.dart' show OpenAIRealtimeVoiceSession;
export 'src/voice_state.dart'
    show
        OpenAIRealtimeVoiceFailure,
        OpenAIRealtimeVoiceMode,
        OpenAIRealtimeVoicePhase,
        OpenAIRealtimeVoiceState;
