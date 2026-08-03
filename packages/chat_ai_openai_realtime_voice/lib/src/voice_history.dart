// Package-private initial-history support for the voice session: the
// synchronous validator and the pure ChatConversation → Realtime
// `conversation.item.create` mapper.
//
// The mapper SEMANTICALLY mirrors the already-accepted translator in
// `package:chat_ai_openai_realtime/.../realtime_request_translator.dart`
// (system → input_text, user text → input_text, user JPEG → input_image,
// assistant text → output_text, matched ToolCall+ToolResult →
// function_call / function_call_output with the `{content,isError}` output
// string), but it is re-implemented HERE — it does not extend or import the
// other package's API.
//
// No item id is placed on the wire: the session sends the history strictly one
// item at a time with the mic off and no `response.create`, so at most ONE
// acknowledgement can ever be outstanding and a client-side id correlation is
// unnecessary (the server assigns the item ids).
//
// The passed [Conversation] is NEVER mutated, normalised, shortened or stored:
// this builder reads it once, synchronously, and returns freshly-built maps.
library;

import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';

/// Validates [conversation] synchronously (BEFORE any mint/network) and returns
/// the ordered Realtime `item` maps to wrap in `conversation.item.create`.
///
/// Validation (throws [ArgumentError]):
/// - only `schemaVersion == 1` is accepted;
/// - a `user` Message with status `sending` is rejected;
/// - an `assistant` Message with status `streaming` is rejected.
///
/// Filtering (never an error — this is storage-history filtering, not a
/// validation failure):
/// - a `failed` user Message is excluded from sending;
/// - `ProviderOpaquePart`, an unmatched (incomplete) `ToolCallPart` and an
///   orphan `ToolResultPart` are dropped;
/// - a user Message that maps to nothing after filtering is dropped — both an
///   empty `parts` list and parts that carry no supported content (e.g. an
///   opaque-only user Message); it stays in the Conversation and no
///   `conversation.item.create` is sent for it;
/// - an `interrupted` assistant Message is preserved;
/// - an assistant Message that maps to nothing after filtering is dropped;
/// - local `Message.id`, statuses, timestamps and attempt keys are never sent.
List<Map<String, Object?>> prepareInitialHistory(Conversation conversation) {
  if (conversation.schemaVersion != 1) {
    throw ArgumentError.value(
      conversation.schemaVersion,
      'initialConversation.schemaVersion',
      'only schemaVersion == 1 is supported',
    );
  }

  final items = <Map<String, Object?>>[];
  for (final message in conversation.messages) {
    switch (message.role) {
      case MessageRole.system:
        items.add(_systemItem(message));
      case MessageRole.user:
        if (message.status == MessageStatus.sending) {
          throw ArgumentError.value(
            'sending',
            'initialConversation',
            'a user Message with status "sending" cannot seed history',
          );
        }
        if (message.status == MessageStatus.failed) {
          // A failed user Message is not an error, but it is excluded.
          break;
        }
        // A user that maps to nothing is dropped, exactly like such an
        // assistant: no item is sent for it and the next Message follows in
        // source order.
        final item = _userItem(message);
        if (item != null) {
          items.add(item);
        }
      case MessageRole.assistant:
        if (message.status == MessageStatus.streaming) {
          throw ArgumentError.value(
            'streaming',
            'initialConversation',
            'an assistant Message with status "streaming" cannot seed history',
          );
        }
        // `interrupted` is preserved; an empty assistant is dropped.
        items.addAll(_assistantItems(message));
    }
  }

  return items;
}

/// A persisted system Message stays a system item; its text parts are joined
/// like the accepted translator does. Opaque parts are dropped.
Map<String, Object?> _systemItem(Message message) {
  final texts = <String>[];
  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        texts.add(text);
      case ProviderOpaquePart():
        break; // dropped
      default:
        break; // no other part kind is carried for a system Message
    }
  }
  return <String, Object?>{
    'type': 'message',
    'role': 'system',
    'content': <Map<String, Object?>>[
      <String, Object?>{'type': 'input_text', 'text': texts.join('\n')},
    ],
  };
}

/// A user Message maps to one user item: `input_text` and `input_image`
/// (`data:image/jpeg;base64,...`) parts in source order. Opaque parts are
/// dropped; audio/file references do not exist in v1.
///
/// Returns `null` when the mapping produced no content at all — an empty
/// `parts` list, or parts that carry nothing supported (an opaque-only user
/// Message). A `content: []` item is never built: the Message is simply not
/// sent. A `TextPart('')` is ordinary content and still maps to an
/// `input_text` with an empty string.
Map<String, Object?>? _userItem(Message message) {
  final content = <Map<String, Object?>>[];
  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        content.add(<String, Object?>{'type': 'input_text', 'text': text});
      case ImagePart(:final bytes):
        content.add(<String, Object?>{
          'type': 'input_image',
          'image_url': 'data:image/jpeg;base64,${base64Encode(bytes)}',
        });
      case ProviderOpaquePart():
        break; // dropped
      default:
        break; // tool parts never ride on a user Message
    }
  }
  if (content.isEmpty) {
    return null;
  }
  return <String, Object?>{
    'type': 'message',
    'role': 'user',
    'content': content,
  };
}

/// Expands one assistant Message into ordered Realtime items: assistant text
/// (`output_text`), and — for each COMPLETED `ToolCallPart` + `ToolResultPart`
/// pair (matched by `toolCallId`) — `function_call` immediately followed by
/// `function_call_output`. An unmatched `ToolCallPart`, an orphan
/// `ToolResultPart` and `ProviderOpaquePart` are dropped. Returns an empty list
/// for an assistant that maps to nothing (it is then not sent).
List<Map<String, Object?>> _assistantItems(Message message) {
  // Index the tool results so a call can find its completed pair regardless of
  // source order; a call with no result is incomplete and dropped.
  final resultsByCallId = <String, ToolResultPart>{};
  for (final part in message.parts) {
    if (part is ToolResultPart) {
      resultsByCallId.putIfAbsent(part.toolCallId, () => part);
    }
  }

  final items = <Map<String, Object?>>[];
  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        items.add(<String, Object?>{
          'type': 'message',
          'role': 'assistant',
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'output_text', 'text': text},
          ],
        });
      case ToolCallPart(:final toolCallId, :final name, :final args):
        final result = resultsByCallId[toolCallId];
        if (result == null) {
          break; // an incomplete tool call is dropped
        }
        items.add(<String, Object?>{
          'type': 'function_call',
          'call_id': toolCallId,
          'name': name,
          'arguments': jsonEncode(args),
        });
        items.add(<String, Object?>{
          'type': 'function_call_output',
          'call_id': toolCallId,
          'output': jsonEncode(<String, Object?>{
            'content': result.content,
            'isError': result.isError,
          }),
        });
      case ToolResultPart():
        break; // emitted next to its matched call, or dropped as an orphan
      case ImagePart():
        break; // an image never rides on an assistant Message
      case ProviderOpaquePart():
        break; // dropped
    }
  }
  return items;
}
