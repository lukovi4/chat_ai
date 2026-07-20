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
/// The public surface is exactly ten declarations: the session
/// ([OpenAIRealtimeVoiceSession]), its [OpenAIRealtimeVoiceMode], the coarse
/// [OpenAIRealtimeVoicePhase] / [OpenAIRealtimeVoiceState] /
/// [OpenAIRealtimeVoiceFailure] surface, the OPTIONAL final-transcript side
/// channel ([OpenAIRealtimeVoiceTranscriptRole] /
/// [OpenAIRealtimeVoiceTranscript]) and the OPTIONAL local-recording side
/// channel ([OpenAIRealtimeVoiceRecordingRole] / [OpenAIRealtimeVoiceRecording]
/// / [OpenAIRealtimeVoiceRecordingFailure]). The WebRTC transport, signaling,
/// session-update builder, cancellation, release and recording helpers are
/// package-internal and never exported.
///
/// Optional final transcripts (default OFF) reuse the events of the SAME direct
/// device → OpenAI Realtime session — no `record_transcribe` and no second
/// audio request. When enabled, the session emits final user and assistant
/// transcripts on [OpenAIRealtimeVoiceSession.transcripts]; input transcription
/// is a separate OpenAI ASR model that may be billed separately. The SAME
/// `transcriptsEnabled` opt-in also drives
/// [OpenAIRealtimeVoiceSession.assistantTranscriptDeltas], a `Stream<String>` of
/// the raw assistant transcript fragments of the current response (verbatim, in
/// order, no id/index/usage; the final `.done` stays on `transcripts`).
///
/// [OpenAIRealtimeVoiceSession.interruptResponse] programmatically cancels the
/// current assistant response (one `response.cancel` + one
/// `output_audio_buffer.clear`). In `conversation` it does NOT end the WebRTC
/// session — it returns to `listening` for the next turn; in `singleTurn` (whose
/// one user turn is already closed) it ends the session as `ended`. Both
/// additions are members of the EXISTING [OpenAIRealtimeVoiceSession] (a
/// `Stream<String>` and a `Future<void>`) — no new type and no new public
/// declaration — so the public surface below stays exactly ten declarations.
///
/// Optional local recording (default OFF) reuses the SAME existing WebRTC local
/// and remote audio tracks — no second microphone and no new network request.
/// When enabled the session writes one standalone `.m4a` (AAC-LC / 16 kHz /
/// mono / 32 kbit/s) file per reply and emits each finished file on
/// [OpenAIRealtimeVoiceSession.recordings], with per-side failures on
/// [OpenAIRealtimeVoiceSession.recordingFailures]. Production recording is iOS
/// only; on Android (and whenever recording is disabled) the voice behaviour is
/// unchanged. Recording is independent of transcripts.
///
/// This increment still does NOT implement tools, playback, waveform,
/// persistence, transcript history, uploads or UI. If `botProfile.tools` is
/// non-empty the session constructor throws synchronously (tools are a later
/// increment).
library;

export 'src/voice_recording.dart'
    show
        OpenAIRealtimeVoiceRecording,
        OpenAIRealtimeVoiceRecordingFailure,
        OpenAIRealtimeVoiceRecordingRole;
export 'src/voice_session.dart' show OpenAIRealtimeVoiceSession;
export 'src/voice_state.dart'
    show
        OpenAIRealtimeVoiceFailure,
        OpenAIRealtimeVoiceMode,
        OpenAIRealtimeVoicePhase,
        OpenAIRealtimeVoiceState;
export 'src/voice_transcript.dart'
    show OpenAIRealtimeVoiceTranscript, OpenAIRealtimeVoiceTranscriptRole;
