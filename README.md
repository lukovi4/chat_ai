# chat_ai

A canonical Flutter chat-with-AI kit for **one open conversation per session**:
streaming replies over a pluggable backend, persisted conversation snapshots,
tool use, image input, recovery commands, and ready chat widgets. Private
package, consumed as a `git:` dependency (not published to pub.dev).

`chat_ai` is an **independent core**: it depends on no transport, no Firebase,
no Dio and no WebRTC. Production transports are separate companion adapter
packages living in this same repository — an app picks the core plus exactly
one adapter:

| App | Packages |
|---|---|
| Firebase-backed apps | `chat_ai` + [`chat_ai_firebase`](packages/chat_ai_firebase/) |
| Solomon (OpenAI Realtime) | `chat_ai` + [`chat_ai_openai_realtime`](packages/chat_ai_openai_realtime/) |

> **Status: OpenAI-only v1.** The Core, `FakeChatBackend` and the three chat
> widgets are implemented and covered by unit and contract tests. The two
> companion adapters carry their own transports and checks: `chat_ai_firebase`
> (HTTP/SSE proxy + reusable Firebase Functions gen2 server template),
> `chat_ai_openai_realtime` (direct WebRTC). Anthropic is explicitly deferred
> to backlog.

## Using the package

See **[docs/USAGE.md](docs/USAGE.md)** for the practical guide: installation,
`ChatSession`, persistence, widgets, Tools, images/dictation callbacks,
failures, and the fake backend in tests.

Adapter-specific setup lives with each adapter:

- **[packages/chat_ai_firebase/](packages/chat_ai_firebase/)** —
  `FirebaseChatBackend`, Firebase setup (Auth, App Check, endpoint), the
  deployable server template and the physical-device smoke example.
- **[packages/chat_ai_openai_realtime/](packages/chat_ai_openai_realtime/)** —
  `OpenAIRealtimeChatBackend`, ephemeral client secrets and the WebRTC
  session model.

## Canonical documents

- [V1_SPEC.md](V1_SPEC.md) — public API, defaults, invariants, and acceptance
  contract.
- [docs/CONTEXT.md](docs/CONTEXT.md) — domain model and terminology.
- [docs/TOOL-SCHEMA-V1.md](docs/TOOL-SCHEMA-V1.md) — the canonical portable
  Tool Schema v1 dialect and its normative fixture corpus.
- [docs/widgets-spec.md](docs/widgets-spec.md) — widget behaviour and
  customization boundaries.
- [docs/adr/](docs/adr/) — accepted architecture decisions.
- The Firebase client/BFF wire and idempotency contract and the server
  template guide live with the adapter:
  [packages/chat_ai_firebase/docs/](packages/chat_ai_firebase/docs/).

## Minimal shape

```dart
import 'package:chat_ai/chat_ai.dart';
// Pick exactly one adapter:
import 'package:chat_ai_firebase/chat_ai_firebase.dart';
// …or: import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart';

final backend = FirebaseChatBackend(
  'https://<region>-<project>.cloudfunctions.net/chat',
);
// …or: OpenAIRealtimeChatBackend(clientSecretProvider: myProvider);

final session = ChatSession(
  backend: backend, // any ChatBackend — the core never picks a transport
  botProfile: const BotProfile(
    id: 'assistant', // server tier id, not a raw model name
    systemPrompt: 'You are a concise assistant.',
    tools: [],
  ),
  checkpoint: saveConversation, // app-owned persistence, before billable sends
);

await session.send('Hello'); // dispatch decision only; observe state for terminal

ChatMessageList(
  session: session,
  failureText: localizeFailure,
);

ChatInputBar(
  session: session,
  hint: 'Message…',
);

await session.dispose();
```

The consuming app owns conversation storage, supplies product policy and
Tools, and configures its chosen adapter (Firebase initialization and the
deployed server template for `chat_ai_firebase`; token issuance and spend
protection for `chat_ai_openai_realtime`). No provider key ever lives in
Flutter code or device configuration.

## What's included

- **Core:** `ChatSession` with one-reply-at-a-time operation safety, streaming,
  cancellation, silent retry, resend/regenerate/edit-and-resend, context
  assembly, image processing, tool cycles, persistence checkpoints, and
  explicit disposal.
- **Backend boundary:** `ChatBackend`, `ChatRequest` and the `BackendEvent`
  catalogue — the contract every adapter implements.
- **Models:** `Conversation`, `Message`, `ContentPart`, `BotProfile`, `Tool`,
  `ToolCall`, `ToolResult`, `Usage`, and `ImageSendOptions`.
- **State:** `ConversationState` (`Idle`, `Sending`, `AwaitingTool`,
  `Streaming`, `Done`, `Failed`, `Cancelled`) and the closed
  `FailureCause` catalogue.
- **Widgets:** `ChatMessageList`, standalone `MessageBubble`, `ChatInputBar`,
  `ChatTheme`, and the builder/callback contracts.
- **Testing entry:** `FakeChatBackend` from `package:chat_ai/testing.dart` — no
  transport, network, or paid provider call.

Production transports are deliberately **not** included — they live in the
companion adapter packages listed above.

## Deliberate boundaries

The package does not own conversation lists or storage, app navigation/state
management, authentication UI, subscription/entitlement policy, an image
picker, audio recording/transcription, full-screen image viewing, or any
provider key. It ships no composite chat screen and no user-facing strings.

v1 supports iOS and Android only. Anthropic, resumable streams, parallel tool
calls, file parts, and other v2 items remain out of scope.

## Code generation

Models use `freezed` / `json_serializable`. Generated `*.freezed.dart` and
`*.g.dart` files are committed and are part of the shipped git dependency.
Consuming apps do **not** run `build_runner` for this package; `flutter pub get`
is sufficient.

Only package maintainers run codegen after changing a model:

```sh
dart run build_runner build --delete-conflicting-outputs
```

Commit generated files alongside the model change.

## Platforms

- iOS 18+
- Android 14 (API 34)+
- no web or desktop in v1

[`freezed`]: https://pub.dev/packages/freezed
[`json_serializable`]: https://pub.dev/packages/json_serializable
