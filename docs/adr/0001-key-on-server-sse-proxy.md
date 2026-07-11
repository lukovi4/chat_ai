---
status: accepted
---

# Provider key on the server, chat streamed via a proxy (BFF) over SSE

The Package talks to OpenAI / Anthropic only through an **AI Backend** abstraction
whose canonical implementation is a **server proxy (BFF)**: the provider API key
lives **only server-side**, the proxy **streams the reply back over SSE**, and the
proxy is the single place that enforces **Entitlement** (free/premium → model),
rate limits, and provider switching. The client's Bot Profile is a *request*; the
server decides the model actually used. This is the industry- and
provider-recommended pattern and mirrors `record_transcribe`'s ADR 0001.

## Considered Options

- **Key embedded in the app (direct-to-provider).** Rejected: a key in a mobile
  binary is trivially extracted by decompilation; "free vs premium" decided on the
  client is a money leak. Every source consulted says keys must never touch the
  client.
- **Key on the server, but `tier→model` baked into the app build.** Rejected:
  changing a model or a pricing rule would then require an App Store / Play release
  (days). Putting the map in **server config** lets models and rules change with no
  app release.
- **WebSocket transport.** Rejected for v1: chat reply streaming is one-directional,
  and SSE is the native, proxy-friendly format both providers already speak.

## Consequences

- A streaming-safe proxy is required: it must **not buffer** the upstream response
  and must use generous timeouts, or long generations get cut mid-stream.
- Entitlement and quota are re-verified **server-side**; the client cannot grant
  itself a model. The Core knows nothing about subscriptions or the `tier→model`
  map.
- Swapping provider (OpenAI ↔ Anthropic) is a server/AI-Backend change, invisible
  to the Core.
- A deployable server template (the BFF) is part of the kit, deployed fresh per
  Consuming App (own key, own billing) — same model as `record_transcribe`.

## Amendment (2026-07-10, implementation hardening)

Server enforcement is executable through four required typed hooks:
`checkEntitlement`, provider-generation `checkRateLimit`, idempotent
`reserveQuota(createOrGet|getExisting, attemptKey)` and idempotent
`settleQuota`. The order is fixed:
Auth/App Check → wire/payload validation → idempotency lookup/claim; an existing
key joins/replays/refuses without another rate/quota operation, while only a new
owner runs entitlement → rate → quota reserve → provider. Missing hooks or a
silent default-allow fail deployment. This adds no business policy to the kit;
each Consuming App supplies its own policy behind the mandatory enforcement
points.
