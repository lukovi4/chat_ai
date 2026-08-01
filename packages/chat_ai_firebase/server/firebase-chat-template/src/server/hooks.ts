// The four required business hooks — the deploy contract each consuming app
// supplies (docs/server-template.md «Typed hooks»; SERVER-CONTRACT §4/§9;
// ADR 0001). These types are pinned VERBATIM from the contract: this increment
// must not widen, narrow or add a hook. The package owns the orchestration that
// calls them; the app owns the business math behind them.
//
// Nothing here is Flutter public API or a new wire contract — it is the internal
// factory/deploy boundary (docs/server-template.md «Ownership and composition
// boundary»).

import type { ReasoningEffort } from 'openai/resources/shared';

/**
 * A resolved tier: provider + model + output cap, plus an optional reasoning
 * effort (server config, ADR 0001). `reasoningEffort` is a server-side tier
 * setting only: when set it becomes the provider request's `reasoning.effort`;
 * when absent the provider request carries no `reasoning` key. Which efforts a
 * configured model supports is an OpenAI/provider-config contract.
 *
 * `compactThreshold` is the equally optional server-side Compact setting: when
 * set it becomes the provider request's automatic
 * `context_management: [{ type: 'compaction', compact_threshold }]`; when absent
 * the request carries no `context_management` key and Compact stays off. The
 * value must be a positive safe integer; whether the configured model supports
 * it (and which value is sensible) is an OpenAI/provider-config contract owned
 * by the deployment.
 */
export type Tier = {
  id: string;
  provider: 'openai' | 'anthropic';
  model: string;
  maxOutputTokens: number;
  reasoningEffort?: Exclude<ReasoningEffort, null>;
  compactThreshold?: number;
};

export type EntitlementResult =
  | { kind: 'allowed'; tier: Tier }
  | { kind: 'denied'; detail?: string };

export type RateLimitResult =
  | { kind: 'allowed' }
  | { kind: 'denied'; retryAfterMs?: number; detail?: string };

export type QuotaReservation = { attemptKey: string; reservationId: string };

export type ReserveQuotaRequest =
  | {
      kind: 'createOrGet';
      uid: string;
      attemptKey: string;
      botId: string;
      tier: Tier;
    }
  | { kind: 'getExisting'; uid: string; attemptKey: string };

export type ReserveQuotaResult =
  | { kind: 'reserved'; reservation: QuotaReservation }
  | { kind: 'denied'; detail?: string }
  // `createOrGet` only: the attempt already has a durable terminal, non-`unbilled`
  // accounting outcome (`billed | estimated | unknown`), so it MUST NOT
  // re-dispatch even after idempotency/replay metadata expiry — the handler
  // returns a pre-stream 410. A terminal `unbilled` ledger is not this: it may
  // reopen to `reserved`. This is a typed variant, never a `denied.detail` string.
  | { kind: 'terminal' };

export type Usage = { inputTokens: number | null; outputTokens: number | null };

export type QuotaOutcome =
  | { kind: 'billed'; usage: Usage }
  | { kind: 'unbilled' }
  | { kind: 'estimated'; usage: Usage }
  | { kind: 'unknown' };

/**
 * The four required hooks (all mandatory; a missing hook or a silent allow-all
 * is a construction/deploy-validation error). `reserveQuota` is idempotent by
 * `attemptKey`: `createOrGet` atomically creates or reuses the ledger;
 * `getExisting` is the stale-recovery read and MUST NOT create a reservation.
 * `settleQuota` is idempotent by `attemptKey`; `unknown` never releases quota.
 */
export interface ChatServerHooks {
  checkEntitlement(uid: string, botId: string): Promise<EntitlementResult>;
  checkRateLimit(uid: string, botId: string): Promise<RateLimitResult>;
  reserveQuota(request: ReserveQuotaRequest): Promise<ReserveQuotaResult>;
  settleQuota(reservation: QuotaReservation, outcome: QuotaOutcome): Promise<void>;
}
