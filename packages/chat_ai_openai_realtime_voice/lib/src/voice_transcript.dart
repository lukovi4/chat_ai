// The public declarations of the OPTIONAL transcript side channels.
//
// A transcript event carries only a coarse [OpenAIRealtimeVoiceTranscriptRole],
// the local [turnId] correlating it with the same reply's delta/recording, an
// [interrupted] flag and the final text, exactly as the live device → OpenAI
// Realtime session delivered it. It deliberately exposes NO provider
// response/item/event ids, timestamps, usage, logprobs, confidence, partials or
// status. The package emits these events; the application alone decides whether
// to display, persist or ignore the text. The package itself never logs or
// stores a transcript — not even in debug/test.
//
// [turnId] is a LOCAL UUID v4 minted by the session (never an OpenAI id): the
// same [turnId] links the delta stream, the final transcript, the recording and
// any recording failure of ONE reply.
library;

/// Which side of the conversation a final transcript belongs to.
enum OpenAIRealtimeVoiceTranscriptRole {
  /// The user's spoken reply, transcribed by OpenAI's separate input ASR model.
  user,

  /// The assistant's spoken audio response.
  assistant,
}

/// One final transcript delivered by the live Realtime session. Immutable and
/// intentionally minimal: a [role], the local [turnId], the [interrupted] flag
/// and the final [text].
///
/// The stream carries ONLY successfully-received final transcripts. A missing
/// user event can simply mean the input ASR did not produce a transcript.
class OpenAIRealtimeVoiceTranscript {
  const OpenAIRealtimeVoiceTranscript({
    required this.role,
    required this.turnId,
    required this.text,
    required this.interrupted,
  });

  /// Whether this is the user's or the assistant's transcript.
  final OpenAIRealtimeVoiceTranscriptRole role;

  /// The LOCAL reply id (UUID v4) this transcript belongs to. It is the SAME id
  /// carried by this reply's [OpenAIRealtimeVoiceTranscriptDelta]s and its
  /// [OpenAIRealtimeVoiceRecording]/failure — never an OpenAI item/response id.
  final String turnId;

  /// The final transcript text, passed through EXACTLY as received — never
  /// trimmed, normalized or merged with deltas. May be an empty string.
  final String text;

  /// True when this is the final transcript of an assistant turn that was
  /// interrupted (barge-in, stop, programmatic interrupt or a guardrail block)
  /// before it finished. A late final transcript of an interrupted turn is still
  /// delivered, carrying `interrupted: true`. Always false for user transcripts.
  final bool interrupted;

  @override
  bool operator ==(Object other) =>
      other is OpenAIRealtimeVoiceTranscript &&
      other.role == role &&
      other.turnId == turnId &&
      other.text == text &&
      other.interrupted == interrupted;

  @override
  int get hashCode => Object.hash(role, turnId, text, interrupted);

  /// A privacy-preserving description: it names the [role], the [turnId], the
  /// [interrupted] flag and the text LENGTH only — never the transcript content,
  /// so the package can never leak it into a log through an accidental
  /// `toString()`.
  @override
  String toString() =>
      'OpenAIRealtimeVoiceTranscript(role: $role, turnId: $turnId, '
      'interrupted: $interrupted, text: ${text.length} chars)';
}

/// One assistant transcript DELTA of the current response. Immutable and
/// intentionally minimal: the local [turnId] of the reply and the raw [delta]
/// fragment.
///
/// The [delta] is passed through EXACTLY as received — never trimmed,
/// normalized, merged, deduplicated or accumulated (two identical adjacent
/// fragments are BOTH emitted). The application assembles any displayed text
/// itself. The same [turnId] links this delta with the reply's final transcript
/// and its recording.
class OpenAIRealtimeVoiceTranscriptDelta {
  const OpenAIRealtimeVoiceTranscriptDelta({
    required this.turnId,
    required this.delta,
  });

  /// The LOCAL reply id (UUID v4) this delta belongs to — the SAME id carried by
  /// the reply's final [OpenAIRealtimeVoiceTranscript] and recording. Never an
  /// OpenAI item/response id.
  final String turnId;

  /// The raw assistant transcript fragment, verbatim and in order.
  final String delta;

  @override
  bool operator ==(Object other) =>
      other is OpenAIRealtimeVoiceTranscriptDelta &&
      other.turnId == turnId &&
      other.delta == delta;

  @override
  int get hashCode => Object.hash(turnId, delta);

  /// A privacy-preserving description: it names the [turnId] and the delta
  /// LENGTH only — never the delta content, so the package can never leak it
  /// into a log through an accidental `toString()`.
  @override
  String toString() =>
      'OpenAIRealtimeVoiceTranscriptDelta(turnId: $turnId, '
      'delta: ${delta.length} chars)';
}
