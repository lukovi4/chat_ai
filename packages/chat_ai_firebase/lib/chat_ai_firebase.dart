/// chat_ai_firebase — the production Firebase transport for `chat_ai`
/// (V1_SPEC §8, SERVER-CONTRACT): one `POST` per send over `dio` with an SSE
/// reply stream, Firebase id-token + App Check attestation headers.
///
/// The public surface is exactly `FirebaseChatBackend`. The internal test
/// seam, the wire encoder and the SSE layers are not exported, and this
/// package never re-exports `chat_ai` — apps import the core barrel
/// themselves.
library;

// Production transport (V1_SPEC §8): the class only — the internal test seam
// and the SSE/wire internals stay unexported.
export 'src/backend/firebase_chat_backend.dart' show FirebaseChatBackend;
