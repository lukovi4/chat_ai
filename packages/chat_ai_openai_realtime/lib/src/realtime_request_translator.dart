// ChatRequest → Realtime `response.create` translator. A pure mapper that
// semantically mirrors the base package's server-side OpenAI translator
// (server/firebase-chat-template/src/providers/openai/request.ts), but emits
// the official Realtime item schema on the device.
//
// Fixed invariants: `conversation: "none"` (stateless out-of-band response),
// `output_modalities: ["text"]`, `parallel_tool_calls: false`, no model, no
// metadata, no previous response id, no audio configuration. Client-only
// bookkeeping (`Message.id/status/createdAt/attemptKey`,
// `ChatRequest.idempotencyKey/wireVersion/botId`) never reaches the payload;
// `ProviderOpaquePart` is dropped entirely regardless of provider.

import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';

/// Builds the exactly-one `response.create` client event of a leg.
///
/// System mapping mirrors the server translator: `request.system` is the
/// leading `instructions`; persisted `system` Messages stay system input
/// items in chronological order, ahead of the ordinary history; user and
/// assistant Messages keep their chronological order and the order of their
/// content parts / tool exchanges.
Map<String, dynamic> buildResponseCreateEvent(ChatRequest request) {
  final systemInput = <Map<String, dynamic>>[];
  final historyInput = <Map<String, dynamic>>[];

  for (final message in request.messages) {
    switch (message.role) {
      case MessageRole.system:
        systemInput.add(_systemItem(message));
      case MessageRole.user:
        historyInput.add(_userItem(message));
      case MessageRole.assistant:
        historyInput.addAll(_assistantItems(message));
    }
  }

  return <String, dynamic>{
    'type': 'response.create',
    'response': <String, dynamic>{
      'conversation': 'none',
      'output_modalities': ['text'],
      'instructions': request.system,
      'input': [...systemInput, ...historyInput],
      'parallel_tool_calls': false,
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            <String, dynamic>{
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
        ],
    },
  };
}

/// A persisted system Message stays a system input item (never user
/// content); its text parts are joined like the server translator does.
Map<String, dynamic> _systemItem(Message message) {
  final texts = <String>[];
  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        texts.add(text);
      case ProviderOpaquePart():
        break; // dropped entirely, regardless of provider
      default:
        throw StateError('unexpected system content part');
    }
  }
  return <String, dynamic>{
    'type': 'message',
    'role': 'system',
    'content': [
      <String, dynamic>{'type': 'input_text', 'text': texts.join('\n')},
    ],
  };
}

/// A user Message maps to one user message item: `input_text` and
/// `input_image` (`data:image/jpeg;base64,...`) parts in source order.
Map<String, dynamic> _userItem(Message message) {
  final content = <Map<String, dynamic>>[];
  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        content.add(<String, dynamic>{'type': 'input_text', 'text': text});
      case ImagePart(:final bytes):
        content.add(<String, dynamic>{
          'type': 'input_image',
          'image_url': 'data:image/jpeg;base64,${base64Encode(bytes)}',
        });
      case ProviderOpaquePart():
        break; // dropped entirely, regardless of provider
      default:
        throw StateError('unexpected user content part');
    }
  }
  return <String, dynamic>{
    'type': 'message',
    'role': 'user',
    'content': content,
  };
}

/// Expands one assistant Message into ordered Realtime input items:
/// assistant text (`output_text`), `function_call` and paired
/// `function_call_output` — in source order. Opaque continuity parts are
/// dropped entirely.
List<Map<String, dynamic>> _assistantItems(Message message) {
  final items = <Map<String, dynamic>>[];
  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        items.add(<String, dynamic>{
          'type': 'message',
          'role': 'assistant',
          'content': [
            <String, dynamic>{'type': 'output_text', 'text': text},
          ],
        });
      case ToolCallPart(:final toolCallId, :final name, :final args):
        items.add(<String, dynamic>{
          'type': 'function_call',
          'call_id': toolCallId,
          'name': name,
          'arguments': jsonEncode(args),
        });
      case ToolResultPart(:final toolCallId, :final content, :final isError):
        // The normalised ToolResult rides as a compact JSON string, keys in
        // the order content → isError — byte-compatible with the base
        // package's server translator (SERVER-CONTRACT §7).
        items.add(<String, dynamic>{
          'type': 'function_call_output',
          'call_id': toolCallId,
          'output': jsonEncode(<String, dynamic>{
            'content': content,
            'isError': isError,
          }),
        });
      case ProviderOpaquePart():
        break; // dropped entirely, regardless of provider
      default:
        throw StateError('unexpected assistant content part');
    }
  }
  return items;
}
