# chat_ai_firebase

The production Firebase transport for the [`chat_ai`](../../README.md)
package. **This package contains only the Firebase `ChatBackend`** — nothing
else: no Core changes, no widgets. The server template and the smoke example
ride along as companions of this transport.

```dart
import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_firebase/chat_ai_firebase.dart';

final backend = FirebaseChatBackend(url);
final session = ChatSession(backend: backend, botProfile: profile);
```

## What it is

- `FirebaseChatBackend(url)` — one `POST` per `send()` over `dio`
  (`ResponseType.stream`) against the deployed proxy endpoint, with the SSE
  reply stream decoded into the core's `BackendEvent`s (V1_SPEC §8,
  `docs/SERVER-CONTRACT.md`).
- Every request carries `Authorization: Bearer <id-token>` (`firebase_auth`)
  and `X-Firebase-AppCheck` (`firebase_app_check`), fetched per request.
- The returned stream never throws: every outcome — auth rejection, HTTP
  status, malformed body, transport break — is a `BackendEvent`.
- Cancelling the subscription is the wire-cancel: the pending HTTP future is
  aborted immediately and the connection is closed.
- A dumb pipe by contract: no retry/backoff (the money-aware loop lives in
  the core), no timeouts, no cancel endpoint.

## What the app owns

- **Firebase initialization.** This package never calls
  `Firebase.initializeApp` and does not depend on `firebase_core` directly —
  the consuming app initializes Firebase (it arrives transitively via
  FlutterFire).
- **The provider key stays on the server.** The device talks only to the
  deployed proxy (`server/firebase-chat-template/`); see ADR 0001.

## Layout

- `lib/` — the adapter: `FirebaseChatBackend`, the wire encoder and the SSE
  layers (internals, not exported).
- `server/firebase-chat-template/` — the deployable Firebase Functions proxy
  owning the server side of `docs/SERVER-CONTRACT.md`.
- `example/` — the physical-device smoke harness (Firebase + deployed
  endpoint).
- `docs/` — the server contract, the server-template guide and the
  Firebase-specific ADRs (0001, 0006).
