# firebase-chat-template

Deployable **Firebase Cloud Functions gen2 (TypeScript) BFF template** for the
`chat_ai` kit. Like the sibling `record_transcribe` template, one copy is
deployed **fresh per consuming app** — its own Firebase project, its own provider
key, its own billing (ADR 0001, V1_SPEC §9, `docs/server-template.md`).

> ⚠️ **This is not a deployable endpoint yet.** This increment implements the
> package-owned request runtime behind the internal
> `createChatHandler(dependencies)` factory: Firebase Auth + App Check
> verification, HTTP/wire validation, the Firestore idempotency lifecycle,
> private-GCS terminal replay, the mandatory business hooks, OpenAI provider
> dispatch, the normalised SSE lifecycle, settlement and cancellation. It is
> **still not deployable** on its own — there is **no** Anthropic adapter, **no**
> app-owned `src/index.ts` composition root, **no** Firebase project / secrets /
> resource names, and deploy validation has not been run. **Do not deploy this
> intermediate commit.** The remaining pieces (Anthropic adapter, the app-owned
> composition root, project/secrets/resource configuration and deploy
> validation) are separate later steps. This template is not v1-complete or
> production-ready.

## What this increment provides

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

`createChatHandler` and its dependency/hook types are exported from
`src/server/index.ts`. This is **server-template internal API** (the composition
boundary in `docs/server-template.md`), **not** Flutter public API and **not** a
new wire contract.

The one **shared normative fixture corpus** for the tool schema lives at the repo
root, `test/contract_fixtures/tool_schema_v1/`, and is read directly by the
TypeScript tests — never copied. Dart and TypeScript must produce the same verdict
for every case.

## Platform & runtime

- **Firebase Cloud Functions gen2**, Node.js runtime **`nodejs24`** — the newest
  GA (non-preview) runtime. `engines.node` pins `>=24`.
- Production dependencies: the official **`openai`** and **`firebase-admin`**
  SDKs. `firebase-admin` supplies the concrete `Auth` / `App Check` / `Firestore`
  / `Bucket` / `Timestamp` types and values the handler is injected with.
- The gen2 HTTP handler signature is expressed with the standard Node `http`
  types (`IncomingMessage & { rawBody }` → `ServerResponse`), which a gen2
  request and an express response satisfy — so the app-owned `onRequest(handler)`
  stays assignable. **`firebase-functions` is intentionally not a dependency of
  this template**: nothing here imports from it, and its current published peer
  range for `firebase-admin` excludes the latest major — adding it would force a
  stale `firebase-admin`. The app-owned composition root (a later increment)
  depends on `firebase-functions` and wraps the handler in `onRequest`.
- Dev-only: `typescript`, `@types/node`, `vitest`. No Anthropic SDK, no
  Ajv/Zod/Express/DI framework.
- **SDK retries must be zero.** The factory verifies each provider client's
  public `maxRetries === 0` field at construction and refuses otherwise; the same
  invariant remains a deploy-validation gate.

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
