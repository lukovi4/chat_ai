// The four required business hooks — the deploy contract each consuming app
// supplies (docs/server-template.md «Typed hooks»; SERVER-CONTRACT §4/§9;
// ADR 0001). These types are pinned VERBATIM from the contract: this increment
// must not widen, narrow or add a hook. The package owns the orchestration that
// calls them; the app owns the business math behind them.
//
// Nothing here is Flutter public API or a new wire contract — it is the internal
// factory/deploy boundary (docs/server-template.md «Ownership and composition
// boundary»).

/** A resolved tier: provider + model + output cap (server config, ADR 0001). */
export type Tier = {
  id: string;
  provider: 'openai' | 'anthropic';
  model: string;
  maxOutputTokens: number;
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
  | { kind: 'denied'; detail?: string };

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
