# firebase-chat-template

Foundation of the **deployable Firebase Cloud Functions gen2 (TypeScript) BFF
template** for the `chat_ai` kit. Like the sibling `record_transcribe` template,
one copy is deployed **fresh per consuming app** — its own Firebase project, its
own provider key, its own billing (ADR 0001, V1_SPEC §9,
`docs/server-template.md`).

> ⚠️ **This is not a deployable endpoint yet.** This increment contains only the
> **contract foundation** (wire types, normalised SSE encoding, the Chat AI Tool
> Schema v1 validator) and the **OpenAI Responses translator** (request mapping +
> stream translation). There is **no** Cloud Function, HTTP handler, Firebase
> Admin/Firestore/GCS adapter, idempotency/replay pipeline, quota hooks or
> Anthropic provider here — and no `createChatHandler(dependencies)` factory or
> app-owned `src/index.ts` composition root yet. The ownership/composition
> boundary (that factory, the `ChatServerHooks`, and the app-owned composition
> root) is **specified** in `docs/server-template.md` («Ownership and composition
> boundary»), **not implemented** in this commit. **Do not deploy this
> intermediate commit** — a partial BFF must never masquerade as a deployable
> endpoint until the money / idempotency / replay pipeline exists (the next
> server increment).

## What this increment provides

| Area | File | Summary |
|---|---|---|
| Wire / domain types | `src/core/wire.ts` | The validated `ChatRequest` shape (mirrors `lib/src/backend/chat_request_wire.dart`) and the five normalised SSE events + the nine wire causes (SERVER-CONTRACT §2/§5). |
| Normalised SSE encoding | `src/core/sse.ts` | Pure `encodeSseFrame` — byte-compatible with the Dart `decodeSseFrame`. No HTTP streaming/keepalive/lifecycle. |
| Chat AI Tool Schema v1 | `src/core/tool-schema.ts` | The exact closed dialect validator (SERVER-CONTRACT §7), mirroring the Dart Core — not a general JSON Schema engine. |
| OpenAI request mapping | `src/providers/openai/request.ts` | Validated `ChatRequest` + resolved tier → exact typed streaming Responses request. |
| OpenAI stream translation | `src/providers/openai/stream.ts` | Typed OpenAI Responses stream → normalised events, with the terminal policy of task §9. |

The one **shared normative fixture corpus** for the tool schema lives at the repo
root, `test/contract_fixtures/tool_schema_v1/`, and is read directly by the
TypeScript tests — never copied. Dart and TypeScript must produce the same verdict
for every case.

## Platform & runtime

- **Firebase Cloud Functions gen2**, Node.js runtime **`nodejs24`** — the newest
  GA (non-preview) runtime for Cloud Run functions / Cloud Functions gen2. The
  `engines.node` field pins `>=24`.
- Production dependency: the official **`openai`** npm SDK. Dev-only:
  `typescript`, `@types/node`, `vitest`. No Firebase packages yet (unused this
  increment), no Anthropic SDK, no Ajv/Zod/Express.

## Scripts

```bash
npm run typecheck   # tsc --noEmit
npm run build       # tsc -> lib/ (gitignored build output)
npm test            # vitest run (unit + fixture; no network, no API key)
```

## Not shipped (per-deployment, never committed)

`.firebaserc`, the Firebase project ID, provider secrets (Secret Manager) and
service-account / admin key JSON are **never** part of this template — each
deployment supplies its own (`.gitignore` enforces this). `package-lock.json`
**is** tracked: this is a deployable app, not a library.
