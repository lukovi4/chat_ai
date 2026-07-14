# Deploy runbook — OpenAI-only smoke

A step-by-step runbook for wiring this template into a **dedicated, non-production
Firebase project** for a physical-device smoke of the full path:

> device → Firebase Auth + App Check → Functions gen2 `chat` → `createChatHandler`
> → OpenAI Responses stream → `FirebaseChatBackend` → `ChatSession` → package widgets.

This is **OpenAI-only** and **not v1-complete / not production-ready** (no Anthropic,
no product policy). It has **not** been deployed or device-tested. Do **not** point
it at a real user project.

> Never place real project IDs, keys, tokens, bucket names or credentials in this
> repo. Everything below is a placeholder you fill locally.

## 1. Create/select a dedicated smoke project

- Create a **new empty** Firebase project (or select an existing throwaway one).
- Do **not** commit `.firebaserc`. Select the project locally only:
  `firebase use <project-id>`

## 2. Pick one region and co-locate everything

Choose a single `<function-region>` (e.g. a Cloud Run region) and **co-locate** the
Function, Firestore and the replay bucket in it — cross-region hops add latency and
egress and are not part of this smoke. This region is the mandatory
`FUNCTION_REGION` parameter below.

## 3. Firestore

- Create a Firestore database (Native mode) **in `<function-region>`**.
- The template uses: `idempotency/**`, `chat-replays` (GCS, not Firestore),
  `usage/**`, `rate/**`.
- **Security rules — deny all client access to the server-only docs.** This
  template ships **no** `firestore.rules` pointer in `firebase.json` (so a deploy
  never overwrites a host app's rules). For the dedicated smoke project, publish
  deny-all rules explicitly:
  1. Firebase Console → **Firestore Database** → **Rules**.
  2. Replace the rules with exactly this (the smoke project holds nothing else):

     ```
     rules_version = '2';
     service cloud.firestore {
       match /databases/{database}/documents {
         // The function's service account uses the Admin SDK and bypasses rules;
         // all direct client access to server-only accounting is denied.
         match /{document=**} { allow read, write: if false; }
       }
     }
     ```

  3. Click **Publish**.
  4. Do **not** add a `firestore.rules` pointer to the reusable `firebase.json`.
- **Firestore TTL:** add a TTL policy on the **terminal** `expiresAt` field of the
  idempotency records — collection group `keys`, field `expiresAt`. TTL is cleanup
  only; the handler treats logical expiry authoritatively.

## 4. Private replay bucket

- Create a **separate private** Cloud Storage bucket **in `<function-region>`** for
  replay objects (`chat-replays/{uid}/{key}/{runId}.sse`).
- Turn **Public Access Prevention** on (enforced).
- Grant the function's runtime service account the minimal object role
  (`roles/storage.objectAdmin`) on **this bucket only**.
- Apply a **lifecycle policy** to delete orphan/expired objects (sample in
  `replay-bucket-lifecycle.json`):
  `gcloud storage buckets update gs://<replay-bucket> --lifecycle-file=replay-bucket-lifecycle.json`

## 5. Set the OpenAI key as a Secret (hidden prompt — never an argument!)

```
firebase functions:secrets:set OPENAI_API_KEY
```

Paste the key at the hidden prompt. The key is **only** in Secret Manager — never
in code, args, README, git or any client config.

## 6. Mandatory deployment parameters

All are required (no permissive defaults; the composition root/deploy fails closed
otherwise). Provide them at the deploy prompts or a params file:

- `FUNCTION_REGION` — the `<function-region>` from step 2 (no default; empty fails
  closed). Passed to `onRequest`'s region option.
- `OPENAI_MODEL` — a vision + streaming + function-calling + strict-tools capable
  OpenAI model id (a deployment choice, never a package default).
- `CHAT_BOT_ID` — the one allowed smoke bot id (must match the client `CHAT_BOT_ID`).
- `REPLAY_BUCKET` — the private replay bucket name from step 4.
- `MAX_OUTPUT_TOKENS`, `RATE_MAX_REQUESTS`, `RATE_WINDOW_SECONDS`,
  `DAILY_ATTEMPT_QUOTA` — positive integers.

## 7. Deploy only the function

```
firebase deploy --only functions
```

`predeploy` runs `npm run build` (emits `lib/`). The exported function is `chat`
(runtime `nodejs24`, region `FUNCTION_REGION`, `timeoutSeconds: 300`, secret
`OPENAI_API_KEY`).

## 8. Invoker IAM (gen2) — network invocation only, Auth/App Check still enforced

gen2 functions are Cloud Run services. To allow the network call to reach the
function, grant the invoker role (replace both placeholders):

```
gcloud run services add-iam-policy-binding chat \
  --project=<project-id> \
  --region=<function-region> \
  --member=allUsers \
  --role=roles/run.invoker
```

Allowing network invocation does **not** weaken security: **Auth + App Check remain
mandatory inside the handler** — a caller without a valid id-token / App Check token
is rejected regardless of IAM.

## 9. Get the endpoint

- Copy the deployed `chat` trigger URL. This is the client `CHAT_ENDPOINT`.

## 10. Local client config (compile-time defines, gitignored)

The Flutter `example/` is **config-free** — it uses **no** native
`google-services.json` / `GoogleService-Info.plist`. Instead, create the local,
gitignored define files and run with `--dart-define-from-file` (see
`example/README.md`):

- `example/firebase.android.local.json`
- `example/firebase.ios.local.json`

Each holds the six defines (`CHAT_ENDPOINT`, `CHAT_BOT_ID`, `FIREBASE_API_KEY`,
`FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`). Never
commit them.

## 11. Run on a physical device

```
flutter run --dart-define-from-file=firebase.android.local.json   # Android
flutter run --dart-define-from-file=firebase.ios.local.json       # iOS
```

Register the App Check **debug token** printed at first launch in the Firebase
console. Missing defines → the app shows a setup screen (no live session).

## 12. Logs (no payloads/keys/tokens)

```
firebase functions:log --only chat
```

The handler never logs body/token/provider/user content; verify none appears.

## 13. Cleanup / revoke after the smoke

- `firebase functions:secrets:destroy OPENAI_API_KEY` (or rotate the key).
- Delete the smoke function, the replay bucket objects, and the smoke Firestore data.
- Remove the App Check debug tokens.
