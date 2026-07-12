/// Internal context assembly + trimming (V1_SPEC §6, CONTEXT §Context
/// Assembly / §Context Trimming). Not exported from the public barrel.
///
/// Assembly filters the snapshot for the wire:
/// - `failed` user Messages are excluded (they never reached the bot);
/// - `interrupted` assistant partials are included;
/// - empty `complete` assistant Messages (no parts) are dropped from the
///   wire but stay in storage/UI;
/// - persisted `system` Messages keep their chronological order and remain
///   contractual system input (the proxy maps them, not the client);
/// - tool/toolResult/providerOpaque parts ride as-is inside their Message —
///   one serializer, no second mapper (`Message.toJson` on the wire).
///
/// Trimming (when [trimBudget] is non-null) runs once, pre-assembly: the
/// Bot Profile system prompt and persisted `system` Messages are always
/// kept; ordinary Messages are kept newest-first while the chars/4 estimate
/// fits the budget, oldest dropped first, whole Messages only. The newest
/// Message is mandatory: if system input + that Message already exceed the
/// budget the result is the degenerate `context-too-long` outcome — the
/// server stays the final arbiter, there is no trim→retry loop.
library;

import 'dart:convert';

import '../models/bot_profile.dart';
import '../models/content_part.dart';
import '../models/message.dart';

/// The outcome of one assembly: either the wire [messages], or the
/// degenerate over-budget verdict ([contextTooLong] `true`).
class AssembledContext {
  const AssembledContext._(this.messages, this.contextTooLong);

  const AssembledContext.fit(List<Message> messages) : this._(messages, false);

  const AssembledContext.overBudget() : this._(const [], true);

  final List<Message> messages;
  final bool contextTooLong;
}

/// Assembles the wire message list for one leg from the current snapshot
/// [history] under the reply's frozen [profile].
AssembledContext assembleContext({
  required List<Message> history,
  required BotProfile profile,
  required int? trimBudget,
}) {
  final wire = <Message>[
    for (final message in history)
      if (_ridesOnWire(message)) message,
  ];
  if (trimBudget == null || wire.isEmpty) {
    return AssembledContext.fit(wire);
  }

  // chars/4 estimate over text-bearing content; the system input (profile
  // prompt + persisted system Messages) is always kept and always counted.
  var budgetLeft = trimBudget - _estimateTokens(profile.systemPrompt.length);
  final ordinary = <Message>[];
  for (final message in wire) {
    if (message.role == MessageRole.system) {
      budgetLeft -= _messageTokens(message);
    } else {
      ordinary.add(message);
    }
  }
  if (ordinary.isEmpty) {
    return budgetLeft < 0
        ? const AssembledContext.overBudget()
        : AssembledContext.fit(wire);
  }

  // Newest-first, the newest Message mandatory.
  final kept = <Message>{};
  for (var i = ordinary.length - 1; i >= 0; i--) {
    final message = ordinary[i];
    final cost = _messageTokens(message);
    if (cost > budgetLeft) {
      if (kept.isEmpty) {
        // Even system + the one mandatory Message does not fit.
        return const AssembledContext.overBudget();
      }
      break; // this Message and everything older is dropped
    }
    budgetLeft -= cost;
    kept.add(message);
  }
  return AssembledContext.fit([
    for (final message in wire)
      if (message.role == MessageRole.system || kept.contains(message)) message,
  ]);
}

bool _ridesOnWire(Message message) {
  if (message.role == MessageRole.user &&
      message.status == MessageStatus.failed) {
    return false;
  }
  if (message.role == MessageRole.assistant &&
      message.status == MessageStatus.complete &&
      message.parts.isEmpty) {
    return false;
  }
  return true;
}

int _estimateTokens(int chars) => (chars + 3) ~/ 4;

/// The chars/4 estimate of one Message: visible text, tool-call name+args
/// JSON and tool-result content. Images and provider-opaque bytes are not
/// "chars" of the dialogue and are deliberately excluded — the server stays
/// the final arbiter (`context-too-long`).
int _messageTokens(Message message) {
  var chars = 0;
  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        chars += text.length;
      case ToolCallPart(:final name, :final args):
        chars += name.length + jsonEncode(args).length;
      case ToolResultPart(:final content):
        chars += content.length;
      case ImagePart():
      case ProviderOpaquePart():
        break;
    }
  }
  return _estimateTokens(chars);
}
