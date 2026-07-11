import 'package:freezed_annotation/freezed_annotation.dart';

part 'usage.freezed.dart';

/// Token accounting for a reply (V1_SPEC §5, §8). Ephemeral — never
/// serialized into the Conversation snapshot.
///
/// On a multi-leg reply (Tool Use Cycle) the Core sums the legs' usage into
/// the reply's `Done(usage)`; [usageRaw] — the provider's raw usage payload —
/// is kept only for single-leg replies.
@freezed
abstract class Usage with _$Usage {
  const factory Usage({
    required int inputTokens,
    required int outputTokens,
    Map<String, dynamic>? usageRaw,
  }) = _Usage;
}
