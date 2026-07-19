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
/// The public surface is exactly seven declarations: the session
/// ([OpenAIRealtimeVoiceSession]), its [OpenAIRealtimeVoiceMode], the coarse
/// [OpenAIRealtimeVoicePhase] / [OpenAIRealtimeVoiceState] /
/// [OpenAIRealtimeVoiceFailure] surface, and the OPTIONAL final-transcript
/// side channel ([OpenAIRealtimeVoiceTranscriptRole] /
/// [OpenAIRealtimeVoiceTranscript]). The WebRTC transport, signaling,
/// session-update builder, cancellation and release helpers are
/// package-internal and never exported.
///
/// Optional final transcripts (default OFF) reuse the events of the SAME direct
/// device → OpenAI Realtime session — no `record_transcribe` and no second
/// audio request. When enabled, the session emits final user and assistant
/// transcripts on [OpenAIRealtimeVoiceSession.transcripts]; input transcription
/// is a separate OpenAI ASR model that may be billed separately.
///
/// This increment still does NOT implement tools, audio recording, playback,
/// waveform, persistence, transcript history or UI. If `botProfile.tools` is
/// non-empty the session constructor throws synchronously (tools are a later
/// increment).
library;

export 'src/voice_session.dart' show OpenAIRealtimeVoiceSession;
export 'src/voice_state.dart'
    show
        OpenAIRealtimeVoiceFailure,
        OpenAIRealtimeVoiceMode,
        OpenAIRealtimeVoicePhase,
        OpenAIRealtimeVoiceState;
export 'src/voice_transcript.dart'
    show OpenAIRealtimeVoiceTranscript, OpenAIRealtimeVoiceTranscriptRole;
