import 'package:freezed_annotation/freezed_annotation.dart';

import 'tool.dart';

part 'bot_profile.freezed.dart';

/// The minimal triad describing who the bot is (ADR 0005, V1_SPEC §5):
/// a server-side tier [id] (the proxy maps it to a model — the client never
/// names models), the [systemPrompt], and the [tools] the bot may call.
///
/// NOT part of the persisted snapshot — it rides with every send (stateless,
/// ADR 0002); switching bots is just the next send with a different profile.
/// No generation parameters by design (ADR 0005).
@freezed
abstract class BotProfile with _$BotProfile {
  const factory BotProfile({
    required String id,
    required String systemPrompt,
    required List<Tool> tools,
  }) = _BotProfile;
}
