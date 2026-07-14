# Usage

A practical guide to using `chat_ai`. Design rationale and exact contracts live
in `V1_SPEC.md`, `docs/CONTEXT.md`, and `docs/SERVER-CONTRACT.md`; this file
answers “how do I wire it into an app?”.

> **Status:** OpenAI-only v1. The Flutter Core, production backend, server
> template, fake backend, and widgets are implemented. Anthropic is backlog and
> is not a v1 deployment option.

## 1. What it is

`chat_ai` owns the mechanism of one open AI conversation:

- ordered messages and exact persisted JSON;
- request assembly and bounded context trimming;
- streaming state and accumulated token text;
- safe retry/recovery and idempotency keys;
- app-owned Tool execution;
- image resize/JPEG encoding;
- ready message-list, bubble, and input widgets.

One `ChatSession` represents one open `Conversation`. A different conversation
means disposing the old session and constructing another one with its saved
history.

The app still owns its conversation list and database, navigation and state
management, authentication UI, product policy, Tool implementations, image
picker, dictation/voice stack, and all user-facing strings.

## 2. Install

The package is private and is not published to pub.dev:

```yaml
# consuming app pubspec.yaml
dependencies:
  chat_ai:
    git:
      url: <private git url>
      ref: main # prefer a release tag when one exists

  # Declare these directly when the app imports/initializes Firebase itself.
  firebase_core: ^4.12.1
  firebase_auth: ^6.5.6
  firebase_app_check: ^0.4.5+2
```

Then run `flutter pub get`. Generated model files already ship in the package;
the consuming app does not run `build_runner` for `chat_ai`.

## 3. Imports

```dart
// Production/app code.
import 'package:chat_ai/chat_ai.dart';

// Tests only.
import 'package:chat_ai/testing.dart';
```

The testing entry exports only `FakeChatBackend`; package internals remain out
of the production API.

## 4. Production setup checklist

End-to-end setup for each consuming app:

1. Add `chat_ai` as a pinned `git:` dependency and run `flutter pub get`.
2. Create/configure the app in its own Firebase project. Add the app-owned
   native config files or generated `firebase_options.dart`; the package ships
   no Firebase project configuration.
3. Initialize Firebase before creating a live chat session.
4. Activate production App Check providers. Debug providers are only for the
   dedicated smoke harness.
5. Sign a Firebase Auth user in. Anonymous sign-in is acceptable only when it
   matches the app's product policy and is enabled in Firebase.
6. Copy/deploy `server/firebase-chat-template` into that app's Firebase project.
   Replace the included smoke composition with app-owned production hooks and
   configuration; follow its README and `docs/server-template.md`.
7. Set `OPENAI_API_KEY` as a Firebase Secret. Never put it in Flutter code,
   `dart-define`, native Firebase config, logs, or source control.
8. Configure the server's tier for the `BotProfile.id` the app sends. The id is
   a server tier request, not a raw OpenAI model name.
9. Give the function a private replay bucket, Firestore/TTL, required IAM, and
   the four real app hooks: entitlement, rate limit, quota reservation, and
   quota settlement.
10. Pass the deployed HTTPS endpoint to `FirebaseChatBackend`.
11. If chats survive app restarts, provide a `checkpoint` that durably stores
    every snapshot before a billable dispatch.
12. Dispose the session when its screen/flow ends.

Typical app startup:

```dart
WidgetsFlutterBinding.ensureInitialized();

await Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform,
);

await FirebaseAppCheck.instance.activate(
  providerAndroid: const AndroidPlayIntegrityProvider(),
  providerApple: const AppleAppAttestWithDeviceCheckFallbackProvider(),
);

// Or use the app's real sign-in flow.
if (FirebaseAuth.instance.currentUser == null) {
  await FirebaseAuth.instance.signInAnonymously();
}
```

`FirebaseChatBackend` reads the current Firebase ID token and App Check token
for every request. It does not initialize Firebase itself.

The included `example/` uses debug attestation and compile-time defines for a
throwaway smoke project. Do not copy those debug choices into production.

## 5. Create a ChatSession

```dart
final backend = FirebaseChatBackend(
  'https://<region>-<project>.cloudfunctions.net/chat',
);

final session = ChatSession(
  backend: backend,
  botProfile: const BotProfile(
    id: 'assistant',
    systemPrompt: 'You are a concise, helpful assistant.',
    tools: [],
  ),
  history: restoredConversation, // null = a new conversation
  checkpoint: saveConversation,  // null only for intentionally ephemeral chat
  trimBudget: null,              // default: trimming disabled
  maxToolTurns: 5,
  retryDeadline: const Duration(seconds: 30),
  imageOptions: const ImageSendOptions(), // 2048 px / JPEG 85 / max 4
);
```

Constructor options:

| Option | Meaning | Default |
|---|---|---|
| `backend` | One-leg transport. Use `FirebaseChatBackend` in production. | required |
| `botProfile` | Server tier id, system prompt, and Tool declarations. | required |
| `onToolCall` | App Tool resolver. Required when `tools` is non-empty. | `null` |
| `history` | Restored schema-v1 conversation. | new conversation |
| `trimBudget` | Approximate chars/4 context budget; keeps system + newest whole messages. | off |
| `maxToolTurns` | Billable tool-loop guard. Must be positive. | `5` |
| `retryDeadline` | Total wall clock for safe silent retries. | `30 s` |
| `imageOptions` | Resize, JPEG quality, and per-message image cap. | `2048 / 85 / 4` |
| `checkpoint` | Durable app save before every potentially billable dispatch. | `null` |

Invalid numeric/Tool configuration throws `ArgumentError`. Invalid restored
history throws `FormatException`. Operational backend/provider outcomes do not
throw; they appear as `ConversationState`.

Changing `session.botProfile` affects the next command. A reply already in
flight keeps the profile captured when it started.

## 6. Build a chat surface

The package ships components, not a composite screen:

```dart
class ChatBody extends StatelessWidget {
  const ChatBody({super.key, required this.session});

  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ChatMessageList(
            session: session,
            failureText: failureText,
            timestamps: TimestampPosition.belowBubble,
            onImageTap: openImageViewer,
          ),
        ),
        SafeArea(
          top: false,
          child: ChatInputBar(
            session: session,
            hint: 'Message…',
            onAttach: pickImages,
            onMic: dictateText,
          ),
        ),
      ],
    );
  }
}
```

`ChatMessageList` subscribes to the session state/token streams, reads the
latest snapshot, owns alignment, thinking/failure rows, resend/regenerate, and
sticky-bottom behaviour.

`MessageBubble` is also exported standalone. It renders one `Message`, owns no
outer alignment or session actions, and can be used in an app-built list.

`ChatInputBar` owns its draft, selection, focus node, and image previews. There
is no public controller/keyboard API in v1. It clears its draft only when the
Core accepted the command; no-op and preprocessing/checkpoint rejection keep it.

## 7. Observe state and send commands

Use `session.state` as the synchronous seed and `session.states` for subsequent
coarse phase changes:

```dart
final stateSub = session.states.listen((state) {
  switch (state) {
    case Idle():
      break;
    case Sending():
      // Request/checkpoint in progress; no visible token yet.
      break;
    case AwaitingTool(:final call):
      // The app resolver is running.
      debugPrint('tool: ${call.name}');
    case Streaming():
      break;
    case Done(:final usage):
      debugPrint('tokens: ${usage?.inputTokens} / ${usage?.outputTokens}');
    case Failed(:final cause, :final phase, :final developerDetail):
      // Localize cause for UI; developerDetail is logs-only.
      debugPrint('$cause at $phase: $developerDetail');
    case Cancelled():
      // Any visible partial remains in the snapshot.
      break;
  }
});

final tokenSub = session.tokens.listen((accumulatedText) {
  // Accumulated visible assistant text, throttled to about 15 emissions/s.
});
```

The widgets already subscribe for you. Subscribe directly only for app state,
analytics, or a custom UI.

Commands:

```dart
await session.send('Hello');
await session.send('', images: rawImageBytes); // image-only is valid

await session.resend(failedUserMessageId);      // last failed user only
await session.regenerate();                     // last applicable reply
await session.editAndResend(userMessageId, 'Edited text');

session.cancel();                               // keep streamed partial
```

The command `Future` completes after the dispatch/no-op/rejection decision; it
does **not** wait for the terminal provider response. Observe `states` for
`Done`, `Failed`, or `Cancelled`.

Only one reply can be in flight. Commands issued while busy are dropped as
no-ops, never queued for a later billable call.

## 8. Persistence and reopening

The app stores `session.snapshot`. `Conversation` deliberately has no database
id; wrap it in the app's own record/key.

```dart
Future<void> saveConversation(Conversation snapshot) async {
  final encoded = jsonEncode(snapshot.toJson());
  await myConversationStore.write(encoded); // app-owned storage
}

Conversation? restoreConversation(String? encoded) {
  if (encoded == null) return null;
  return Conversation.fromJson(
    (jsonDecode(encoded) as Map<Object?, Object?>).cast<String, dynamic>(),
  );
}
```

Pass `saveConversation` as `checkpoint` when persistence spans launches. The
Core calls it after creating/updating the Message and idempotency key, but before
every potentially billable first/tool/fallback dispatch. A failed checkpoint
prevents that backend call.

On reopen, the constructor normalizes stale in-flight statuses (`sending` →
`failed`, `streaming` → `interrupted`) and validates all schema-v1 invariants.
Unknown schema versions or malformed data fail loudly with `FormatException`.

`BotProfile` and `Usage` are not part of the persisted conversation. The app
chooses the current profile when it opens the session.

## 9. Tools

Tools are app capabilities, not package implementations. Declare them using the
closed Chat AI Tool Schema v1 dialect:

```dart
const searchNotesTool = Tool(
  name: 'search_notes',
  description: 'Searches the signed-in user notes.',
  parameters: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
    },
    'required': ['query'],
    'additionalProperties': false,
  },
);

Future<ToolResult> resolveTool(ToolCall call) async {
  if (call.name != 'search_notes') {
    return const ToolResult(content: 'unknown-tool', isError: true);
  }

  final query = call.args['query'] as String;
  final matches = await notesRepository.search(query);
  return ToolResult(content: jsonEncode(matches), isError: false);
}

final session = ChatSession(
  backend: backend,
  botProfile: const BotProfile(
    id: 'assistant',
    systemPrompt: 'Use search_notes when the user asks about saved notes.',
    tools: [searchNotesTool],
  ),
  onToolCall: resolveTool,
  checkpoint: saveConversation,
);
```

Important rules:

- A profile with Tools but no resolver is an `ArgumentError`.
- Names/schemas are validated at session construction and profile assignment.
- Tool execution is **at least once**. If a Tool writes data, deduplicate by
  `ToolCall.id` before performing the side effect.
- Unknown names, invalid arguments, and resolver exceptions become sanitized
  `isError` results; exception text and stack traces never go to the model.
- Tool parts are persisted inside the assistant Message and hidden by default.
  Use `partBuilder` only if the app wants to show a product-specific tool row.
- The Core has no Tool timeout. The user can still cancel the reply.

## 10. Images and dictation

The package requests no permissions and includes no picker. `OnAttach` returns
raw bytes from the app's chosen picker:

```dart
Future<List<Uint8List>> pickImages() async {
  final files = await imagePicker.pickMultiImage();
  return Future.wait(files.map((file) => file.readAsBytes()));
}
```

The Core validates, resizes off the UI isolate, and re-encodes JPEG before it
creates the Message. Defaults are a 2048 px longest edge, quality 85, and four
images per message. Configure them per session with `ImageSendOptions`.

`ChatInputBar.maxAttachments` may only lower the session cap. `[]` from
`OnAttach` means the picker was cancelled. The app owns camera/gallery
permissions and full-screen image viewing (`onImageTap`).

`OnMic` is dictation glue only:

```dart
Future<String?> dictateText() async {
  return speechService.captureText();
}
```

The returned text is inserted at the input selection and is never sent
automatically. The package records no audio, asks for no microphone permission,
and has no dependency on `record_transcribe`.

## 11. Widget customization

All visual defaults derive from the app's `Theme`. Use one `ChatTheme` for the
list, bubbles, and input bar:

```dart
const chatTheme = ChatTheme(
  messageListPadding: EdgeInsets.all(16),
  bubblePadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  messageSpacing: 10,
  maxBubbleWidthFactor: 0.82,
  imageThumbnailSize: Size(180, 180),
);
```

Invalid sizes/factors throw `ArgumentError` during build in both debug and
release; values are never silently clamped.

Customization levels:

- layout switches on `ChatMessageList`: own-message side, avatars, avatar side,
  timestamps, and assistant markdown;
- builders: avatar, thinking, failure row, empty reply, and individual parts;
- `partBuilder` sees text/image/tool-call/tool-result parts; returning `null`
  selects default rendering. It never sees provider-opaque continuity state;
- tool parts are hidden by default;
- assistant text uses markdown by default; user/system text is plain;
- long-press copies visible text parts only;
- no package-owned user-facing strings.

`failureText` is required even when the default visuals are otherwise enough:

```dart
String failureText(FailureCause cause) => switch (cause) {
  FailureCause.auth => 'Please sign in again.',
  FailureCause.entitlement => 'This assistant is unavailable.',
  FailureCause.quota => 'Your limit has been reached.',
  FailureCause.rate => 'Too many requests. Try again shortly.',
  FailureCause.overloaded => 'The service is busy.',
  FailureCause.contentFilter => 'That request was filtered.',
  FailureCause.contextTooLong => 'This conversation is too long.',
  FailureCause.network => 'Check your connection.',
  FailureCause.upstream => 'The service failed. Try again.',
  FailureCause.toolLoopLimit => 'The tool loop was stopped.',
};
```

If `errorBuilder` is supplied, it replaces the default failure row. Its `retry`
callback is nullable: `null` means the current failure has no valid recovery,
so the app must not show a fake retry action.

## 12. Failures and recovery

`FailureCause` is a machine code, never display text. `Failed.phase` tells
whether the reply failed before visible text (`sending`) or after
(`streaming`). `developerDetail` is sanitized technical context for logs only;
never show it to the user.

Recovery behaviour:

- `resend(id)` applies only to the **last** failed user Message. It never
  truncates later history.
- `regenerate()` recovers an interrupted reply (or the applicable final sent
  user), and explicitly creates a new attempt for a completed reply.
- `editAndResend(id, text)` truncates after that user Message, replaces its text,
  keeps its already-processed images, and sends under a fresh key. The app owns
  any confirmation/copy-before-truncate UI.
- `cancel()` closes the client stream, lands on `Cancelled`, keeps visible
  partial text, and ignores late events. The server-side upstream abort is
  best-effort; idempotency/replay protects explicit recovery.

The Core silently retries only safe pre-token `rate`, `overloaded`, and
`network` failures within `retryDeadline`. It never silently retries after
visible output.

## 13. Fake backend in tests

`FakeChatBackend` drives the real Core without Firebase, network, or paid calls:

```dart
import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai/testing.dart';

test('reply reaches Done', () async {
  final fake = FakeChatBackend()..reply('Hello from the fake.');
  final session = ChatSession(
    backend: fake,
    botProfile: const BotProfile(
      id: 'test-bot',
      systemPrompt: 'Test assistant.',
      tools: [],
    ),
  );

  final terminal = session.states.firstWhere((state) => state is Done);
  await session.send('Hello');
  await terminal;

  final assistant = session.snapshot.messages.last;
  expect(assistant.status, MessageStatus.complete);
  expect((assistant.parts.single as TextPart).text, 'Hello from the fake.');

  await session.dispose();
});
```

These public methods enqueue one backend response each:

```dart
fake.reply('text', tokenDelay: const Duration(milliseconds: 10));
fake.failWith(FailureCause.quota);          // pre-stream failure
fake.breakAfterFirstToken();                // interrupted partial
fake.requestTool('search_notes', args: {'query': 'sleep'});
fake.emptyReply();
fake.respondGone410();
fake.respondConflict409();
```

`replayOnSameKey()` is different: it enables replay of a previously recorded
terminal response when the Core repeats the same idempotency key; it does not
enqueue a response itself.

```dart
fake.replayOnSameKey();
```

An exhausted script returns a valid empty reply. The public fake deliberately
has no matcher framework or request-inspection API.

## 14. Lifecycle

Create one session per open conversation, normally in `initState`, and dispose
it when that conversation leaves memory:

```dart
@override
void dispose() {
  unawaited(session.dispose());
  super.dispose();
}
```

Outside a Flutter `State.dispose`, prefer `await session.dispose()`. Disposal is
idempotent, cancels active transport/backoff, waits for pending teardown, closes
both streams, and prevents late async work from dispatching or mutating state.

Calling commands after disposal is a programming error and throws `StateError`.

## 15. Not in v1

- Anthropic adapter/SDK/dispatch (backlog; reserved discriminator values remain
  for compatibility).
- Conversation list/database, search, archive, sync, or app navigation.
- Composite chat screen or state-management integration.
- App authentication/subscription/paywall/quota policy.
- Image picker, full-screen viewer, audio recording, or transcription.
- Resumable streaming after process death, parallel tool calls, file parts, and
  other v2 protocol features.
- Web and desktop support.
- Public text/focus/scroll controllers or built-in edit UI.

## 16. Rules to follow

- The OpenAI key is never on the device. Flutter talks only to the app's BFF.
- Use `ChatSession` for app chat flow; calling a raw `ChatBackend` directly
  bypasses context, retry, recovery, state, checkpoints, Tools, and image work.
- One session equals one open conversation; there is no command queue.
- Persist `Conversation.toJson()`, not ephemeral state/usage.
- Provide a checkpoint when persistence crosses launches.
- Deduplicate side-effecting Tools by `ToolCall.id`.
- Localize `FailureCause`; never show `developerDetail`.
- Dispose every session.
- Keep production business hooks fail-closed; the smoke hooks are not product
  policy.
- Do not rely on v2/backlog behaviour until its contract is explicitly added.

## 17. Further references

- [Package overview](../README.md)
- [Public v1 contract](../V1_SPEC.md)
- [Domain model](CONTEXT.md)
- [Server/wire contract](SERVER-CONTRACT.md)
- [Widget specification](widgets-spec.md)
- [Server template guide](server-template.md)
- [Server template README](../server/firebase-chat-template/README.md)
- [Physical-device smoke](../example/README.md)
