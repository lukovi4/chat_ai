# chat_ai

A canonical Flutter chat-with-AI kit for **one open conversation per session**:
streaming replies over a pluggable backend, persisted conversation snapshots,
tool use, image input, recovery commands, and ready chat widgets. Private
package, consumed as a `git:` dependency (not published to pub.dev).

> **Status: OpenAI-only v1.** The Core, `FirebaseChatBackend`, reusable Firebase
> Functions gen2 server template, `FakeChatBackend`, and the three chat widgets
> are implemented and covered by unit, contract, server, and physical-device
> smoke tests on iOS and Android. Anthropic is explicitly deferred to backlog.

## Using the package

See **[docs/USAGE.md](docs/USAGE.md)** for the practical guide: installation,
the production setup checklist, `ChatSession`, persistence, widgets, Tools,
images/dictation callbacks, failures, and the fake backend in tests.

For a manual live check, **[example/](example/)** is a physical-device smoke
harness against a deployed OpenAI-only endpoint. It is deliberately not a
production sample app.

## Canonical documents

- [V1_SPEC.md](V1_SPEC.md) — public API, defaults, invariants, and acceptance
  contract.
- [docs/CONTEXT.md](docs/CONTEXT.md) — domain model and terminology.
- [docs/SERVER-CONTRACT.md](docs/SERVER-CONTRACT.md) — client/BFF wire and
  idempotency contract.
- [docs/widgets-spec.md](docs/widgets-spec.md) — widget behaviour and
  customization boundaries.
- [docs/server-template.md](docs/server-template.md) — server ownership,
  hooks, storage, and deployment invariants.
- [docs/adr/](docs/adr/) — accepted architecture decisions.

## Minimal shape

```dart
import 'package:chat_ai/chat_ai.dart';

final session = ChatSession(
  backend: FirebaseChatBackend(
    'https://<region>-<project>.cloudfunctions.net/chat',
  ),
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

The consuming app initializes Firebase, signs a user in, activates App Check,
owns conversation storage, supplies product policy and Tools, and deploys its
own copy of the server template. The OpenAI key lives only in the server's
Secret Manager — never in Flutter code or device configuration.

## What's included

- **Core:** `ChatSession` with one-reply-at-a-time operation safety, streaming,
  cancellation, silent retry, resend/regenerate/edit-and-resend, context
  assembly, image processing, tool cycles, persistence checkpoints, and
  explicit disposal.
- **Production backend:** `FirebaseChatBackend` (Firebase Auth + App Check +
  dio/SSE) pointed at the app's deployed function.
- **Server template:** Firebase Functions gen2 BFF with mandatory Auth/App
  Check, idempotency/replay, quota hooks, OpenAI Responses translation, and
  fail-closed deployment validation.
- **Models:** `Conversation`, `Message`, `ContentPart`, `BotProfile`, `Tool`,
  `ToolCall`, `ToolResult`, `Usage`, and `ImageSendOptions`.
- **State:** `ConversationState` (`Idle`, `Sending`, `AwaitingTool`,
  `Streaming`, `Done`, `Failed`, `Cancelled`) and the closed
  `FailureCause` catalogue.
- **Widgets:** `ChatMessageList`, standalone `MessageBubble`, `ChatInputBar`,
  `ChatTheme`, and the builder/callback contracts.
- **Testing entry:** `FakeChatBackend` from `package:chat_ai/testing.dart` — no
  Firebase, network, or paid provider call.

## Deliberate boundaries

The package does not own conversation lists or storage, app navigation/state
management, authentication UI, subscription/entitlement policy, an image
picker, audio recording/transcription, full-screen image viewing, or the
OpenAI key. It ships no composite chat screen and no user-facing strings.

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
