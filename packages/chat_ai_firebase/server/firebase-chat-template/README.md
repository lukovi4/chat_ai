# firebase-chat-template

> **README of this deployable template only** — not the integration guide of the
> `chat_ai_firebase` package and not of the kit. How an app chooses a variant,
> installs the packages and wires `ChatSession` is in the repository
> [README.md](../../../../README.md); the ownership/composition rules of the
> template are in [`docs/server-template.md`](../../docs/server-template.md).

Deployable **Firebase Cloud Functions gen2 (TypeScript) BFF template** for the
`chat_ai` kit. Like the sibling `record_transcribe` template, one copy is
deployed **fresh per consuming app** — its own Firebase project, its own provider
key, its own billing (ADR 0001, V1_SPEC §9, `docs/server-template.md`).

> **v1 provider scope: OpenAI Responses only.** Two layers
> live here, and the split matters:
>
> - **Reusable package-owned runtime** (`src/server/**`, behind the internal
>   `createChatHandler(dependencies)` factory): Firebase Auth + App Check
>   verification, HTTP/wire validation, the Firestore idempotency lifecycle,
>   private-GCS terminal replay, the four mandatory business hooks, OpenAI
>   provider dispatch, the normalised SSE lifecycle, settlement and cancellation.
>   A consuming app never rewrites this.
> - **App-owned OpenAI smoke composition** (`src/index.ts`, `src/smoke/hooks.ts`,
>   `firebase.json`, `DEPLOY_SMOKE.md`, `replay-bucket-lifecycle.json`, and the
>   Flutter `example/`): a thin composition root + real Firestore business hooks
>   for a **dedicated, non-production smoke project**. This is app-owned
>   deployment glue, not package API.
>
> Anthropic is explicitly deferred to the product backlog and does not block
> v1. The included composition has **no production policy**: its hooks are for a
> dedicated smoke project, while each consuming app supplies its own production
> business hooks. The OpenAI **API key never touches the client** — it lives only in
> Secret Manager (`OPENAI_API_KEY`). Deploy this **only** to a throwaway smoke
> project you own; it is not a production endpoint.

## What v1 provides

| Area | File(s) | Summary |
|---|---|---|
| Contract foundation | `src/core/*`, `src/providers/openai/*` | Wire/domain types, the normalised SSE encoder, the Chat AI Tool Schema v1 validator, and the OpenAI Responses request/stream translators (prior increment; reused unchanged). |
| Factory + dependencies | `src/server/dependencies.ts`, `src/server/hooks.ts` | `ChatServerDependencies` and the four required `ChatServerHooks` (verbatim from `docs/server-template.md`). All dependencies are injected concrete SDK instances; no global Firebase state. |
| Request handler | `src/server/handler.ts` | `createChatHandler` — fail-closed construction checks, then the full per-request pipeline (POST → Auth/App Check → wire validation → idempotency claim → admission → OpenAI dispatch → SSE → strict terminal commit → settlement → cancellation). |
| Canonical hashing | `src/server/canonical.ts` | Canonical JSON + `requestHash` / `paramsHash` provider-effective projections (SERVER-CONTRACT §6). |
| HTTP/wire validation | `src/server/validation.ts` | Narrows an unknown body into the exact closed `ChatRequest`, re-checks the toolset, validates the UUID v4 `Idempotency-Key`. |
| Idempotency lifecycle | `src/server/firestore.ts` | Firestore claim/join/stale/complete/aborted/conflict transitions, all atomic. |
| Replay store | `src/server/replay.ts` | Create-only private-GCS object write + finalize + byte/SHA-256 verification, replay read, release object, old-run cleanup. |
| Provider dispatch | `src/server/openai.ts` | The exact structured safe-release allowlist and the runtime `maxRetries: 0` check. |
| Transport | `src/server/transport.ts` | The gen2-compatible handler signature, pre-stream error replies and the SSE writer (headers + 15 s keepalive + disconnect detection). |
| Reply runner | `src/runner/*` | `runChatReply` — one full logical reply (multi-leg, server-side tool loop, structured terminal, aggregated usage) with no HTTP/SSE lifecycle and no Firebase. See «Connection-independent reply runner» in `docs/server-template.md`. |

`createChatHandler` and its dependency/hook types are exported from
`src/server/index.ts`. This is **server-template internal API** (the composition
boundary in `docs/server-template.md`), **not** Flutter public API and **not** a
new wire contract.

The connection-independent runner is exported from the Firebase-free barrel
`src/runner/index.ts` (and re-exported from `src/server/index.ts`). A detached
app-owned worker imports it from `./runner`; the worker host, persistence,
admission and deployment around it are the application's.

The one **shared normative fixture corpus** for the tool schema lives at the repo
root, `test/contract_fixtures/tool_schema_v1/`, and is read directly by the
TypeScript tests — never copied. Dart and TypeScript must produce the same verdict
for every case.

## Platform & runtime

- **Firebase Cloud Functions gen2**, Node.js runtime **`nodejs22`** (set in
  `firebase.json`, which is authoritative for the deployed runtime — Cloud
  Functions for Firebase supports Node.js 20 and 22). `engines.node` pins the
  local toolchain to exactly that major, **`"22"`**, and the local type
  definitions (`@types/node`) track the **22.x** branch so they describe the same
  runtime that is deployed. `main` points at `lib/index.js`.
- Production dependencies: the official **`openai`**, **`firebase-admin`** and
  **`firebase-functions`** SDKs. `firebase-admin` supplies the concrete `Auth` /
  `App Check` / `Firestore` / `Bucket` / `Timestamp` types/values injected into
  the handler; `firebase-functions` supplies `onRequest` + params/secrets for the
  app-owned composition root.
- The gen2 HTTP handler signature is expressed with the standard Node `http`
  types (`IncomingMessage & { rawBody }` → `ServerResponse`), which a gen2
  request and an express response satisfy — so `onRequest(handler)` compiles with
  no cast.
- **Temporary dependency exception (documented on purpose).** The kit rule is
  latest-only, but the latest `firebase-functions` (`^7.2.5`) still declares a
  `firebase-admin` peer range of `^11 || ^12 || ^13` — it does **not** yet accept
  `firebase-admin@14`. To keep a clean, conflict-free install (no
  `--legacy-peer-deps`, no `--force`, no overrides), `firebase-admin` is pinned
  **exactly to `13.10.0`** (the latest compatible 13.x). **Removal condition:** as
  soon as a latest `firebase-functions` accepts `firebase-admin@14`, drop the pin
  and move back to latest `firebase-admin`.
- **Deliberate `@types/node` pin (runtime alignment, not a temporary exception).**
  `@types/node` is held on major **22** on purpose: the type definitions must
  describe the Firebase production runtime (`nodejs22`), and a newer major would
  type APIs the deployed runtime does not have.
- Because of those two pins, **`npm outdated` may list `firebase-admin` *and*
  `@types/node`** — that output is expected and is not, by itself, a reason to bump
  either. In particular the newer `@types/node` majors are **not** permission to
  raise the runtime above Node 22: `firebase.json` decides the runtime, and it must
  stay on a version Cloud Functions for Firebase actually supports. `@types/node`
  moves only when the pinned Firebase runtime itself moves.
- Dev-only: `typescript`, `@types/node`, `vitest`. No Anthropic SDK (backlog), no
  Ajv/Zod/Express/DI framework.
- **SDK retries must be zero.** The factory verifies each provider client's
  public `maxRetries === 0` field at construction and refuses otherwise; the
  composition root builds the OpenAI client with `maxRetries: 0`.

## Deploying the OpenAI-only smoke

`src/index.ts` is the **app-owned** composition root: it initializes Firebase
Admin, reads the mandatory deployment parameters + the `OPENAI_API_KEY` secret,
builds the four business hooks (`src/smoke/hooks.ts`, real Firestore rate/quota)
and hands the injected dependencies to `createChatHandler`, wrapped in the gen2
`chat` function. The Flutter `example/` drives it from a physical device. The full
step-by-step runbook (dedicated non-production project, private replay bucket,
App Check debug, secret, parameters, deploy, logs, cleanup) is in
**`DEPLOY_SMOKE.md`**. Nothing here is deployed by this task.

## Scripts

```bash
npm run typecheck   # tsc --noEmit
npm run build       # tsc -> lib/ (gitignored build output)
npm test            # vitest run (unit + integration; no network, no API key, no real Firebase)
```

All tests use in-memory concrete stand-ins for the injected dependencies (the
factory test seam) — no network, no emulator, no real Firebase project or tokens.

## Not shipped (per-deployment, never committed)

`.firebaserc`, the Firebase project ID, provider secrets (Secret Manager) and
service-account / admin key JSON are **never** part of this template — each
deployment supplies its own (`.gitignore` enforces this). `package-lock.json`
**is** tracked: this is a deployable app, not a library.
