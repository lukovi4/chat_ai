import 'content_part.dart';
import 'conversation.dart';
import 'message.dart';

/// Internal read-boundary validation (V1_SPEC §5 "Invariants") — invoked from
/// `Conversation.fromJson`, NOT a public validator API. Throws
/// [FormatException] naming the offending Message on the first violation.
///
/// Checked here:
/// - `Message.id` values are unique inside the Conversation;
/// - role ↔ status: `user → sending|sent|failed`,
///   `assistant → streaming|complete|interrupted`, `system → complete`;
/// - `attemptKey` is required on `user`/`assistant` Messages and forbidden on
///   `system` Messages;
/// - `system` Messages are text-only; tool and provider-opaque parts never
///   appear on `user`/`system` Messages;
/// - ignoring [ProviderOpaquePart]s, assistant parts follow the visible
///   grammar `text* (toolCall toolResult text*)* toolCall?` — the trailing
///   unmatched `toolCall` is legal only on `streaming`/`interrupted`, a
///   `toolResult` matches the nearest unclosed call, and `toolCallId` is
///   unique inside the Message (one reply = one assistant Message);
/// - `ProviderOpaquePart.provider` is `openai` or `anthropic`.
void checkConversationInvariants(Conversation conversation) {
  final seenIds = <String>{};
  for (final message in conversation.messages) {
    if (!seenIds.add(message.id)) {
      throw FormatException(
        'Duplicate Message.id "${message.id}" in Conversation',
      );
    }
    _checkMessage(message);
  }
}

void _checkMessage(Message message) {
  switch (message.role) {
    case MessageRole.user:
      _require(
        const {
          MessageStatus.sending,
          MessageStatus.sent,
          MessageStatus.failed,
        }.contains(message.status),
        message,
        'a user Message must be sending|sent|failed, got ${message.status.name}',
      );
      _require(
        message.attemptKey != null,
        message,
        'a user Message must have an attemptKey',
      );
      for (final part in message.parts) {
        _require(
          part is TextPart || part is ImagePart,
          message,
          'tool and provider-opaque parts never appear on a user Message',
        );
      }
    case MessageRole.assistant:
      _require(
        const {
          MessageStatus.streaming,
          MessageStatus.complete,
          MessageStatus.interrupted,
        }.contains(message.status),
        message,
        'an assistant Message must be streaming|complete|interrupted, '
        'got ${message.status.name}',
      );
      _require(
        message.attemptKey != null,
        message,
        'an assistant Message must have an attemptKey',
      );
      _checkAssistantGrammar(message);
    case MessageRole.system:
      _require(
        message.status == MessageStatus.complete,
        message,
        'a system Message is always complete, got ${message.status.name}',
      );
      _require(
        message.attemptKey == null,
        message,
        'a system Message must not have an attemptKey',
      );
      for (final part in message.parts) {
        _require(part is TextPart, message, 'a system Message is text-only');
      }
  }
}

/// The visible grammar of one logical reply (V1_SPEC §5):
/// `text* (toolCall toolResult text*)* toolCall?`, ignoring provider-opaque
/// parts.
void _checkAssistantGrammar(Message message) {
  final seenToolCallIds = <String>{};
  ToolCallPart? openCall;
  for (final part in message.parts) {
    switch (part) {
      case ProviderOpaquePart(:final provider):
        // Ignored for the grammar; the field itself is still constrained.
        _require(
          provider == 'openai' || provider == 'anthropic',
          message,
          'ProviderOpaquePart.provider must be "openai" or "anthropic", '
          'got "$provider"',
        );
      case TextPart():
        _require(
          openCall == null,
          message,
          'text cannot appear between a toolCall and its toolResult',
        );
      case ImagePart():
        throw FormatException(
          'Message "${message.id}": an image part never appears on an '
          'assistant Message',
        );
      case ToolCallPart():
        _require(
          openCall == null,
          message,
          'a second toolCall cannot open before the previous one is resolved '
          '(no parallel tool calls in v1)',
        );
        _require(
          seenToolCallIds.add(part.toolCallId),
          message,
          'duplicate toolCallId "${part.toolCallId}" inside one reply',
        );
        openCall = part;
      case ToolResultPart():
        final open = openCall;
        if (open == null) {
          throw FormatException(
            'Message "${message.id}": a toolResult must follow its toolCall',
          );
        }
        _require(
          part.toolCallId == open.toolCallId,
          message,
          'toolResult "${part.toolCallId}" does not match the open toolCall '
          '"${open.toolCallId}"',
        );
        openCall = null;
    }
  }
  _require(
    openCall == null || message.status != MessageStatus.complete,
    message,
    'a complete assistant Message never has an unmatched trailing toolCall',
  );
}

void _require(bool condition, Message message, String violation) {
  if (!condition) {
    throw FormatException('Message "${message.id}": $violation');
  }
}
