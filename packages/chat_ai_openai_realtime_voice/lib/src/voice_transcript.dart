// The two public declarations of the OPTIONAL final-transcript side channel.
//
// A transcript event carries only a coarse [OpenAIRealtimeVoiceTranscriptRole]
// and the final text, exactly as the live device → OpenAI Realtime session
// delivered it. It deliberately exposes NO provider response/item/event ids,
// timestamps, usage, logprobs, confidence, deltas, partials or status. The
// package emits these events; the application alone decides whether to display,
// persist or ignore the text. The package itself never logs or stores a
// transcript — not even in debug/test.
library;

/// Which side of the conversation a final transcript belongs to.
enum OpenAIRealtimeVoiceTranscriptRole {
  /// The user's spoken reply, transcribed by OpenAI's separate input ASR model.
  user,

  /// The assistant's spoken audio response.
  assistant,
}

/// One final transcript delivered by the live Realtime session. Immutable and
/// intentionally minimal: only a [role] and the final [text].
///
/// The stream carries ONLY successfully-received final transcripts. A missing
/// user event can simply mean the input ASR did not produce a transcript.
class OpenAIRealtimeVoiceTranscript {
  const OpenAIRealtimeVoiceTranscript({required this.role, required this.text});

  /// Whether this is the user's or the assistant's transcript.
  final OpenAIRealtimeVoiceTranscriptRole role;

  /// The final transcript text, passed through EXACTLY as received — never
  /// trimmed, normalized or merged with deltas. May be an empty string.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is OpenAIRealtimeVoiceTranscript &&
      other.role == role &&
      other.text == text;

  @override
  int get hashCode => Object.hash(role, text);

  /// A privacy-preserving description: it names the [role] and the text LENGTH
  /// only — never the transcript content, so the package can never leak it into
  /// a log through an accidental `toString()`.
  @override
  String toString() =>
      'OpenAIRealtimeVoiceTranscript(role: $role, text: ${text.length} chars)';
}
