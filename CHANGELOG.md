# Changelog

## Unreleased

Package split: `chat_ai` is now an independent, transport-free core with two
companion adapter packages living in this same repository.

- **BREAKING (package surface):** `FirebaseChatBackend` is no longer exported
  from `package:chat_ai/chat_ai.dart`. The Firebase adapter — the transport,
  the SSE layers, the server template, the smoke example and the Firebase
  docs — moved to `packages/chat_ai_firebase`. A Firebase app adds the
  `chat_ai_firebase` package dependency (same repository,
  `path: packages/chat_ai_firebase`) and one import
  (`package:chat_ai_firebase/chat_ai_firebase.dart`); the
  `FirebaseChatBackend(url)` configuration, the wire format and the runtime
  behaviour are unchanged. No conversation/data migration is needed.
- The OpenAI Realtime adapter lives at `packages/chat_ai_openai_realtime`
  (`OpenAIRealtimeChatBackend`).
- The core dropped its `dio`, `firebase_auth` and `firebase_app_check`
  dependencies; it now carries no transport dependency at all.
- Core contracts and behaviour are unchanged: `ChatSession`, `ChatBackend`,
  `ChatRequest`, `BackendEvent`, the models/JSON, the state machine, the
  widgets and `FakeChatBackend` are untouched.
- The canonical Tool Schema v1 rules now live in `docs/TOOL-SCHEMA-V1.md`;
  the fixture corpus stays at `test/contract_fixtures/tool_schema_v1`.

## 1.0.0 - 2026-07-15

First v1 release of the `chat_ai` chat-with-AI kit — a private git dependency,
not published to pub.dev. This initial OpenAI-only v1 is versioned 1.0.0 and
prepared for its release tag.

### Included
- **ChatSession Core** — one open conversation per session: one-reply-at-a-time
  operation safety, streaming with a throttled token stream, cancellation, silent
  pre-token retry within a deadline, `send`/`resend`/`regenerate`/`editAndResend`,
  stateless context assembly with optional trimming, an idempotency key per
  attempt, persistence checkpoints before every billable dispatch, and explicit
  disposal.
- **FirebaseChatBackend** — production transport: one POST per send over dio with
  SSE, a Firebase Auth id-token + App Check attestation attached per request, and
  a stream that never throws (every outcome is a `BackendEvent`, not an
  exception).
- **Models, persistence, and state** — `Conversation`, `Message`, `ContentPart`,
  `BotProfile`, `Tool`, `ToolCall`, `ToolResult`, `Usage`, and `ImageSendOptions`;
  the exact schema-v1 storage JSON with invariant-checked reads; and
  `ConversationState` (`Idle`/`Sending`/`AwaitingTool`/`Streaming`/`Done`/
  `Failed`/`Cancelled`) plus the closed `FailureCause` catalogue.
- **Tools and images** — app-owned Tool declarations in the closed Chat AI Tool
  Schema v1 dialect, an at-least-once resolver with `ToolCall.id` deduplication,
  and off-isolate image resize/JPEG re-encode from raw picker bytes.
- **Widgets** — `ChatMessageList`, standalone `MessageBubble`, and `ChatInputBar`
  with `ChatTheme`, layout switches, and builder/callback slots; no composite
  chat screen and no user-facing strings.
- **FakeChatBackend** (`package:chat_ai/testing.dart`) — a scriptable backend
  that drives the real Core in tests with no Firebase, network, or paid provider
  call.
- **Firebase Functions gen2 server template** (`server/firebase-chat-template/`)
  — a reusable BFF deployed fresh per consuming app: mandatory Auth/App Check, the
  Firestore idempotency lifecycle, private-GCS terminal replay, the four required
  business hooks (entitlement, rate limit, quota reservation, quota settlement),
  strict terminal commit, and fail-closed deploy validation.
- **OpenAI-only runtime** — the server dispatches to OpenAI Responses only, with
  the provider client built at `maxRetries: 0` under the idempotency layer; the
  OpenAI key lives only in Secret Manager and never reaches the device.
- **iOS/Android physical-device smoke harness** (`example/`) — drives the real
  package widgets and Core against a deployed OpenAI-only endpoint; a throwaway
  smoke composition using debug attestation and compile-time defines, deliberately
  not a production sample app.
- **Integration documentation** — `README.md`, `docs/USAGE.md`, and the canonical
  `V1_SPEC.md`, `docs/*`, and `docs/adr/*` references.

### Not in v1 (planned)
- **Anthropic** adapter/SDK/dispatch — deferred to the product backlog. Reserved
  discriminator values (`anthropic`) remain for compatibility, but v1 installs no
  Anthropic SDK, performs no dispatch, and fail-closed rejects such a tier.
- Resumable streaming after process death, parallel tool calls, and file content
  parts.
- Conversation list/database, search/archive/sync, app navigation, a composite
  chat screen, and state-management integration.
- Web and desktop support.
