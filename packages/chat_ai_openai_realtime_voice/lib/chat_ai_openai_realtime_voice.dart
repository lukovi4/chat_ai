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
/// The public surface is exactly fourteen declarations: the session
/// ([OpenAIRealtimeVoiceSession]), its [OpenAIRealtimeVoiceMode], the coarse
/// [OpenAIRealtimeVoicePhase] / [OpenAIRealtimeVoiceState] /
/// [OpenAIRealtimeVoiceFailure] surface, the OPTIONAL transcript side channel
/// ([OpenAIRealtimeVoiceTranscriptRole] / [OpenAIRealtimeVoiceTranscript] /
/// [OpenAIRealtimeVoiceTranscriptDelta]), the OPTIONAL local-recording side
/// channel ([OpenAIRealtimeVoiceRecordingRole] / [OpenAIRealtimeVoiceRecording]
/// / [OpenAIRealtimeVoiceRecordingFailure]) and the OPTIONAL output-guardrail
/// surface ([OpenAIRealtimeVoiceGuardrailDecision] /
/// [OpenAIRealtimeVoiceOutputGuardrail] / [OpenAIRealtimeVoiceGuardrailEvent]).
/// The universal INITIAL HISTORY and TOOLS reuse the core `chat_ai`
/// `Conversation` / `Tool` / `ToolCall` / `ToolResult` / `OnToolCall` types and
/// add no new public declaration. The WebRTC transport, signaling, session-update
/// builder, tool/history/guardrail helpers, cancellation, release and recording
/// helpers are package-internal and never exported.
///
/// Optional final transcripts (default OFF) reuse the events of the SAME direct
/// device → OpenAI Realtime session — no `record_transcribe` and no second
/// audio request. When enabled, the session emits final user and assistant
/// transcripts on [OpenAIRealtimeVoiceSession.transcripts]; input transcription
/// is a separate OpenAI ASR model that may be billed separately. The SAME
/// `transcriptsEnabled` opt-in also drives
/// [OpenAIRealtimeVoiceSession.assistantTranscriptDeltas], a
/// `Stream<OpenAIRealtimeVoiceTranscriptDelta>` of the raw assistant transcript
/// fragments of the current response (verbatim, in order, each carrying the
/// reply's local `turnId`; the final `.done` stays on `transcripts`). Every
/// reply is tagged with a LOCAL `turnId` (UUID v4, never an OpenAI id) that links
/// its delta, its final transcript and its recording / recording failure.
///
/// [OpenAIRealtimeVoiceSession.interruptResponse] programmatically cancels the
/// current assistant response (one `response.cancel` + one
/// `output_audio_buffer.clear`). In `conversation` it does NOT end the WebRTC
/// session — it returns to `listening` for the next turn; in `singleTurn` (whose
/// one user turn is already closed) it ends the session as `ended`.
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
/// This increment adds an optional INITIAL HISTORY (seeded as strictly
/// ack-correlated `conversation.item.create` items before the mic goes live),
/// universal TOOLS (the core `Tool`/`ToolCall`/`ToolResult`/`OnToolCall` with a
/// money-safe per-reply `maxToolTurns` cap, default 5) and an optional
/// low-latency post-generation output GUARDRAIL that fails closed with a single
/// no-context replacement. It still does NOT implement playback, waveform,
/// persistence, transcript history, uploads, an on-device classifier or UI; and
/// there is no reconnect/retry/re-mint. The `maxToolTurns = 5` cap and the
/// guardrail's fixed 250 ms check interval are limits of THIS package, not of
/// the OpenAI Realtime API.
library;

export 'src/voice_guardrail.dart'
    show
        OpenAIRealtimeVoiceGuardrailDecision,
        OpenAIRealtimeVoiceGuardrailEvent,
        OpenAIRealtimeVoiceOutputGuardrail;
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
    show
        OpenAIRealtimeVoiceTranscript,
        OpenAIRealtimeVoiceTranscriptDelta,
        OpenAIRealtimeVoiceTranscriptRole;
