import 'package:freezed_annotation/freezed_annotation.dart';

part 'tool.freezed.dart';

/// One Tool declaration the bot may call (V1_SPEC §5, ADR 0003/0005).
///
/// [parameters] is a JSON Schema in exactly the portable **Chat AI Tool
/// Schema v1** dialect (docs/TOOL-SCHEMA-V1.md). Schema/name validation is a
/// session-construction guard (`ArgumentError`, V1_SPEC §3/§5) and ships with
/// the ChatSession increment — this value object carries the declaration.
@freezed
abstract class Tool with _$Tool {
  const factory Tool({
    required String name,
    required String description,
    required Map<String, dynamic> parameters,
  }) = _Tool;
}

/// The bot's request to run an app Tool, handed to the app's `onToolCall`
/// resolver (V1_SPEC §5). [id] is the provider's call id normalized by the
/// proxy; an app whose Tool writes anywhere MUST deduplicate by it — tool
/// execution is at-least-once (V1_SPEC §4).
@freezed
abstract class ToolCall with _$ToolCall {
  const factory ToolCall({
    required String id,
    required String name,
    required Map<String, dynamic> args,
  }) = _ToolCall;
}

/// The app's answer to a [ToolCall] (V1_SPEC §5). With [isError] `true` the
/// bot is told the Tool failed and decides how to react — an error result is
/// never a chat Failure.
@freezed
abstract class ToolResult with _$ToolResult {
  const factory ToolResult({required String content, required bool isError}) =
      _ToolResult;
}

/// The app's tool resolver (V1_SPEC §5): given the bot's [ToolCall], runs the
/// Tool and returns its [ToolResult]. Supplied to `ChatSession` (a later
/// increment); execution is at-least-once, so an app whose Tool writes
/// anywhere MUST deduplicate by `ToolCall.id` (V1_SPEC §4).
typedef OnToolCall = Future<ToolResult> Function(ToolCall call);
