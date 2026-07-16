# Usage — chat_ai_firebase

The Firebase-specific setup of the `chat_ai` kit: installation, Firebase
initialization, App Check, the deployed endpoint and the server template.
Everything transport-agnostic — `ChatSession`, widgets, persistence, Tools,
images, the fake backend, lifecycle — lives in the core guide:
[`docs/USAGE.md`](../../../docs/USAGE.md) at the repo root.

## 1. Install

The packages are private and are not published to pub.dev. Pin the core and
the adapter to **one and the same full 40-character commit SHA**:

```yaml
# consuming app pubspec.yaml
dependencies:
  chat_ai:
    git:
      url: <private git url>
      ref: <full-40-character-commit-sha>
  chat_ai_firebase:
    git:
      url: <private git url>              # the same repository
      ref: <full-40-character-commit-sha> # the SAME full SHA as chat_ai
      path: packages/chat_ai_firebase

  # Declare these directly: the app imports/initializes Firebase itself.
  # chat_ai_firebase deliberately has no direct firebase_core dependency.
  firebase_core: ^4.12.1
  firebase_auth: ^6.5.6
  firebase_app_check: ^0.4.5+2
```

> **The `ref` must be the full 40-character commit SHA — never a branch, a
> tag or a shortened SHA.** `chat_ai_firebase` depends on `chat_ai` through
> a package-local relative `path: ../..`, which Pub normalizes to the fully
> resolved commit SHA. A direct app dependency written as a branch (`main`),
> a tag or a short SHA is a *different source description*, and Pub may fail
> version solving with it even though it points at the same commit. A
> convenient tag-based release scheme is a separate Increment 4 decision.

## 2. Imports

```dart
import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_firebase/chat_ai_firebase.dart';
```

The adapter barrel exports exactly `FirebaseChatBackend` and never re-exports
`chat_ai`.

## 3. Production setup checklist

1. Create/configure the app in its own Firebase project. Add the app-owned
   native config files or generated `firebase_options.dart`; the package ships
   no Firebase project configuration.
2. Initialize Firebase before creating a live chat session.
3. Activate production App Check providers. Debug providers are only for the
   dedicated smoke harness.
4. Sign a Firebase Auth user in. Anonymous sign-in is acceptable only when it
   matches the app's product policy and is enabled in Firebase.
5. Copy/deploy `server/firebase-chat-template` into that app's Firebase
   project. Replace the included smoke composition with app-owned production
   hooks and configuration; follow its README and
   [`server-template.md`](server-template.md).
6. Set `OPENAI_API_KEY` as a Firebase Secret. Never put it in Flutter code,
   `dart-define`, native Firebase config, logs, or source control.
7. Configure the server's tier for the `BotProfile.id` the app sends. The id
   is a server tier request, not a raw OpenAI model name.
8. Give the function a private replay bucket, Firestore/TTL, required IAM, and
   the four real app hooks: entitlement, rate limit, quota reservation, and
   quota settlement.
9. Pass the deployed HTTPS endpoint to `FirebaseChatBackend`.

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

The included [`example/`](../example/) uses debug attestation and
compile-time defines for a throwaway smoke project. Do not copy those debug
choices into production.

## 4. Create the backend

```dart
final backend = FirebaseChatBackend(
  'https://<region>-<project>.cloudfunctions.net/chat',
);

final session = ChatSession(backend: backend, botProfile: profile);
```

The URL constructor is the whole public configuration surface. Everything
else — `ChatSession` options, widgets, persistence, Tools — is the core's and
is documented in the core guide.

## 5. Rules to follow

- The OpenAI key is never on the device. Flutter talks only to the app's BFF.
- Keep production business hooks fail-closed; the smoke hooks are not product
  policy.

## 6. Further references

- [Core usage guide](../../../docs/USAGE.md)
- [Server/wire contract](SERVER-CONTRACT.md)
- [Server template guide](server-template.md)
- [Server template README](../server/firebase-chat-template/README.md)
- [Physical-device smoke](../example/README.md)
- [Tool Schema v1 (canonical core document)](../../../docs/TOOL-SCHEMA-V1.md)
