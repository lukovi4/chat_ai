/// chat_ai — a canonical Flutter chat-with-AI kit: one open conversation per
/// session, streaming replies over a pluggable backend, tool use, and chat
/// widgets (V1_SPEC).
///
/// This is the **foundation increment** of the public surface: the persisted
/// value models + their exact JSON contract (V1_SPEC §5), the ephemeral state
/// and configuration values, and the backend/event contracts (V1_SPEC §8) —
/// no transport, no `ChatSession`, no widgets yet. Internal validators and
/// json helpers are not exported; the fake backend will live in
/// `package:chat_ai/testing.dart`.
library;

// Backend boundary (V1_SPEC §8): the abstraction, its request and its events.
export 'src/backend/backend_event.dart';
export 'src/backend/chat_backend.dart';
export 'src/backend/chat_request.dart';
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
