# chat_ai smoke harness

A minimal **physical-device smoke** for the `chat_ai` package: it drives the
**real** package widgets (`ChatMessageList`, `ChatInputBar`) and Core
(`ChatSession` + `FirebaseChatBackend`) against the **deployed OpenAI-only v1 smoke
endpoint**. It is **not** a production sample app — no router, no state
framework, no persistence, no analytics, no fake mode, no direct OpenAI call.

The OpenAI key is **never on the device**: it lives only in the server's Secret
Manager. This harness only holds a Firebase id-token + App Check token.

## Prerequisites

- A deployed smoke `chat` function (see
  `../server/firebase-chat-template/DEPLOY_SMOKE.md`).
- The smoke Firebase project with **Anonymous** Auth and **App Check** enabled.

## Fixed identifiers

- iOS bundle id / Android application id: **`com.chataismoke.example`** (register
  both in the smoke Firebase project).
- iOS deployment target: **18.0**. Android `minSdk`: **34**.

## Configuration — compile-time defines only (config-free)

This harness bundles **no** `google-services.json` / `GoogleService-Info.plist`
and no `firebase_options.dart`. Everything is injected via six compile-time
defines, so the same build is reusable for any smoke project:

`CHAT_ENDPOINT`, `CHAT_BOT_ID`, `FIREBASE_API_KEY`, `FIREBASE_APP_ID`,
`FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`.

Put them in a **local, gitignored** file per platform. `FIREBASE_API_KEY` is a
Firebase *client* config value (not the provider secret), but is still kept only
in these local files.

`firebase.android.local.json` (placeholder — fill with your smoke project's
Android app values):

```json
{
  "CHAT_ENDPOINT": "https://<function-region>-<project-id>.cloudfunctions.net/chat",
  "CHAT_BOT_ID": "<your-CHAT_BOT_ID>",
  "FIREBASE_API_KEY": "<android-firebase-api-key>",
  "FIREBASE_APP_ID": "<android-firebase-app-id>",
  "FIREBASE_MESSAGING_SENDER_ID": "<messaging-sender-id>",
  "FIREBASE_PROJECT_ID": "<project-id>"
}
```

`firebase.ios.local.json` (placeholder — fill with your smoke project's iOS app
values):

```json
{
  "CHAT_ENDPOINT": "https://<function-region>-<project-id>.cloudfunctions.net/chat",
  "CHAT_BOT_ID": "<your-CHAT_BOT_ID>",
  "FIREBASE_API_KEY": "<ios-firebase-api-key>",
  "FIREBASE_APP_ID": "<ios-firebase-app-id>",
  "FIREBASE_MESSAGING_SENDER_ID": "<messaging-sender-id>",
  "FIREBASE_PROJECT_ID": "<project-id>"
}
```

Both files are gitignored. `CHAT_BOT_ID` must equal the server's `CHAT_BOT_ID`
parameter.

## Run (physical device)

```
# Android
flutter run --dart-define-from-file=firebase.android.local.json

# iOS
flutter run --dart-define-from-file=firebase.ios.local.json
```

If any required define is missing, the app shows a **setup screen** listing the
missing define **names** (never their values) and never opens a live session.

## App Check debug token

On first launch the App Check **debug provider** prints a debug token to the
device log. Register it in the Firebase console (App Check → your app → Manage
debug tokens). Debug attestation is for the smoke only, never production.

## Manual smoke scenarios

Run each against the live endpoint and record the result (form below):

1. **Streaming** — send a Unicode prompt; the reply streams incrementally, then
   `Done` with a usage line.
2. **Image** — attach an image (📎), send a prompt about it, get a reply.
3. **Cancel** — send, then stop mid-stream: state becomes `Cancelled`, the
   partial is kept, and late tokens never mutate the UI.
4. **Resend** — after a failed last user message, resend it.
5. **Regenerate** — regenerate an interrupted (or empty complete) assistant reply.
6. **Tool loop** — ask "what time is it?"; the bot calls `get_device_time`, the
   app returns the ISO-8601 timestamp, and the reply finishes with `Done`.
7. **No leakage** — check the server logs (`firebase functions:log --only chat`):
   no payload, key or token appears.

## Result log

| Date (UTC) | Device / OS | App build | Function revision | Scenario | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
|  |  |  |  | 1 streaming |  |  |
|  |  |  |  | 2 image |  |  |
|  |  |  |  | 3 cancel |  |  |
|  |  |  |  | 4 resend |  |  |
|  |  |  |  | 5 regenerate |  |  |
|  |  |  |  | 6 tool loop |  |  |
|  |  |  |  | 7 no leakage |  |  |

## Build without a config

`flutter build apk --debug` and `flutter build ios --simulator --no-codesign`
build without any local Firebase config: with no defines the runtime shows the
setup screen. Never commit real values or native config files.
