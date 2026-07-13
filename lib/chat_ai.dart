/// chat_ai — a canonical Flutter chat-with-AI kit: one open conversation per
/// session, streaming replies over a pluggable backend, tool use, and chat
/// widgets (V1_SPEC).
///
/// The public surface: the `ChatSession` Core façade (V1_SPEC §3/§4), the
/// persisted value models + their exact JSON contract (V1_SPEC §5), the
/// ephemeral state and configuration values, the backend/event contracts and
/// the production `FirebaseChatBackend` transport (V1_SPEC §8), and the three
/// chat widgets — `ChatMessageList`, `MessageBubble`, `ChatInputBar` — with
/// `ChatTheme` and the widget enums/builder typedefs (V1_SPEC §3/§7).
/// Internal validators, json helpers, the wire encoder, the SSE layers, the
/// tool-schema validator, the Core test seams, the widget theme
/// resolver/validation helpers and the command-disposition bridge are not
/// exported; the fake backend lives in `package:chat_ai/testing.dart` only.
library;

// Backend boundary (V1_SPEC §8): the abstraction, its request and its events.
export 'src/backend/backend_event.dart';
export 'src/backend/chat_backend.dart';
export 'src/backend/chat_request.dart';
// Production transport (V1_SPEC §8): the class only — the internal test seam
// and the SSE/wire internals stay unexported.
export 'src/backend/firebase_chat_backend.dart' show FirebaseChatBackend;
// The Core façade (V1_SPEC §3): the session and the checkpoint contract only —
// the command-disposition bridge, the widgets' imageOptions bridge and the
// internal test seam stay unexported.
export 'src/core/chat_session.dart' show ChatSession, ConversationCheckpoint;
// Persisted snapshot models + configuration values (V1_SPEC §5).
export 'src/models/bot_profile.dart';
export 'src/models/content_part.dart';
export 'src/models/conversation.dart';
export 'src/models/failure.dart';
export 'src/models/image_send_options.dart';
export 'src/models/message.dart';
export 'src/models/tool.dart';
export 'src/models/usage.dart';
// Ephemeral session phase (V1_SPEC §4/§5).
export 'src/state/conversation_state.dart';
// Chat widgets (V1_SPEC §7): the three widgets, the theme value class and
// the §3 widget enums/typedefs — the package-internal theme
// resolver/validation helpers stay unexported.
export 'src/widgets/chat_input_bar.dart' show ChatInputBar;
export 'src/widgets/chat_message_list.dart' show ChatMessageList;
export 'src/widgets/chat_theme.dart' show ChatTheme;
export 'src/widgets/message_bubble.dart' show MessageBubble;
export 'src/widgets/widget_contracts.dart';
