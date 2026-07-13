// OpenAI provider dispatch support: the exact safe-release allowlist and the
// zero-retry deploy check (SERVER-CONTRACT §6/§10, task §8/§9). The streaming
// call itself lives in the handler (it reuses `buildOpenAIResponsesRequest`,
// `translateOpenAIStream` and `encodeSseFrame` around the injected client and an
// AbortSignal). Classification is STRUCTURED ONLY — HTTP status, the documented
// error `code` and headers — never `error.message` text.

import { APIError } from 'openai';
import type OpenAI from 'openai';

import type { WireCause } from '../core/wire';

/**
 * A pre-stream provider rejection classified against the closed v1 allowlist:
 * `release` makes the key unknown again (safe retry), `aborted` fails closed and
 * refuses the key with a tombstone. `retryAfterMs` rides only with a released
 * rate-limit.
 */
export interface OpenAIErrorClassification {
  cause: WireCause;
  disposition: 'release' | 'aborted';
  retryAfterMs?: number;
}

const RELEASE_RATE: OpenAIErrorClassification = { cause: 'rate', disposition: 'release' };
const ABORT_UPSTREAM: OpenAIErrorClassification = { cause: 'upstream', disposition: 'aborted' };
const ABORT_CONTEXT: OpenAIErrorClassification = {
  cause: 'context-too-long',
  disposition: 'aborted',
};

/** Reads `retry-after-ms` / `retry-after` (seconds) from provider headers. */
function parseRetryAfterMs(headers: Headers | undefined): number | undefined {
  if (headers === undefined) return undefined;
  const rawMs = headers.get('retry-after-ms');
  if (rawMs !== null) {
    const ms = Number(rawMs);
    if (Number.isFinite(ms) && ms >= 0) return Math.round(ms);
  }
  const rawSeconds = headers.get('retry-after');
  if (rawSeconds !== null) {
    const seconds = Number(rawSeconds);
    if (Number.isFinite(seconds) && seconds >= 0) return Math.round(seconds * 1000);
  }
  return undefined;
}

/**
 * Classifies a pre-stream OpenAI failure. The ONLY release case is a documented
 * retryable rate-limit `429 rate_limit_exceeded`; `insufficient_quota`, an
 * invalid key, a bare/unknown 429, every 5xx and any connection failure without
 * a public zero-request-bytes proof fail closed to `aborted` (SERVER-CONTRACT
 * §6/§10; task §9). `context_length_exceeded` maps to `context-too-long` but is
 * NOT released.
 */
export function classifyOpenAIError(error: unknown): OpenAIErrorClassification {
  if (!(error instanceof APIError)) {
    // Connection/timeout/unknown throw: no SDK proof that zero request bytes
    // were written, so the outcome is ambiguous — fail closed.
    return ABORT_UPSTREAM;
  }

  // Documented context-length error → context-too-long, never released.
  if (error.code === 'context_length_exceeded') return ABORT_CONTEXT;

  if (error.status === 429) {
    if (error.code === 'rate_limit_exceeded') {
      const retryAfterMs = parseRetryAfterMs(error.headers);
      return retryAfterMs === undefined ? RELEASE_RATE : { ...RELEASE_RATE, retryAfterMs };
    }
    // insufficient_quota, provider credit/key errors and any bare/unknown 429.
    return ABORT_UPSTREAM;
  }

  // Every other provider status (invalid key 401/403, 500/502/503/504, unknown
  // 4xx/5xx) is ambiguous or a deployer-key problem → aborted upstream.
  return ABORT_UPSTREAM;
}

/**
 * The deploy check the factory can prove at runtime: the installed OpenAI SDK
 * exposes `maxRetries` as a public client field, so a nonzero value is a
 * construction error (SDK retries must be zero under the idempotency layer,
 * SERVER-CONTRACT §1; task §8).
 */
export function hasZeroRetries(client: OpenAI): boolean {
  return client.maxRetries === 0;
}
