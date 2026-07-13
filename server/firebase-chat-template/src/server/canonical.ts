// Canonical JSON + the two idempotency hashes (SERVER-CONTRACT §6, task §5).
// Pure and deterministic: no Firebase, no provider, no clock.
//
// Canonical JSON: every object key sorted lexicographically at every level,
// List order preserved, scalars untouched, compact (no insignificant
// whitespace), UTF-8. SHA-256 over that byte string, hex-encoded.
//
// Both hashes share ONE cleaned protocol projection of the validated
// ChatRequest — `wireVersion` removed, and `id`/`status`/`createdAt`/
// `attemptKey` removed from every Message (the client/protocol-only fields the
// proxy ignores). The ONLY difference is provider-opaque filtering:
//   - `requestHash` keeps every `providerOpaque` part (provider not yet known);
//   - `paramsHash` keeps matching-provider opaque byte-exact and drops
//     foreign-provider opaque, per the stored provider.
// Neither includes app configuration, model or `maxOutputTokens`.

import { createHash } from 'node:crypto';

import type { ChatRequest, WireContentPart, WireMessage } from '../core/wire';

/** Recursively sorts object keys; arrays keep order; scalars pass through. */
function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value !== null && typeof value === 'object') {
    const source = value as Record<string, unknown>;
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(source).sort()) {
      sorted[key] = canonicalize(source[key]);
    }
    return sorted;
  }
  return value;
}

/** Compact canonical JSON (keys sorted at every level, list order preserved). */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

/** SHA-256 hex of a UTF-8 string or raw bytes. */
export function sha256Hex(data: string | Uint8Array): string {
  return createHash('sha256').update(data).digest('hex');
}

/**
 * Deterministic, collision-free encoding of a raw Firebase uid into a single
 * storage-safe path segment: the UTF-8 bytes of the uid, base64url (no padding,
 * no `/` `.` `..`). Used identically for the Firestore path and the GCS object
 * path so an unusual uid (a `/`, a dot segment, Unicode) cannot escape its
 * namespace or collide. The raw uid is still passed unchanged to auth and to the
 * application hooks; only the storage paths use this encoding (no wire/API
 * change).
 */
export function storageSafeUid(uid: string): string {
  return Buffer.from(uid, 'utf8').toString('base64url');
}

/** Which provider-opaque parts survive the projection. */
type OpaquePolicy = 'all' | 'openai' | 'anthropic';

function projectParts(parts: WireContentPart[], policy: OpaquePolicy): WireContentPart[] {
  if (policy === 'all') return parts;
  return parts.filter((part) => part.type !== 'providerOpaque' || part.provider === policy);
}

/**
 * One Message stripped to its provider-effective content: only `role` + `parts`
 * survive (the four bookkeeping fields are dropped). Foreign-provider opaque
 * parts are dropped when `policy` names a provider.
 */
function projectMessage(message: WireMessage, policy: OpaquePolicy): Record<string, unknown> {
  return { role: message.role, parts: projectParts(message.parts, policy) };
}

/** The shared cleaned projection of the request (no `wireVersion`). */
function projectRequest(request: ChatRequest, policy: OpaquePolicy): Record<string, unknown> {
  const projection: Record<string, unknown> = {
    botId: request.botId,
    system: request.system,
    messages: request.messages.map((message) => projectMessage(message, policy)),
  };
  if (request.tools !== undefined) {
    projection.tools = request.tools;
  }
  return projection;
}

/**
 * Provisional canonical input hash for the `running` record before provider
 * resolution: every `providerOpaque` part is kept (task §5, SERVER-CONTRACT §6).
 */
export function requestHash(request: ChatRequest): string {
  return sha256Hex(canonicalJson(projectRequest(request, 'all')));
}

/**
 * Provider-effective canonical hash frozen with the resolved provider: opaque
 * parts of the stored provider are kept byte-exact, foreign ones dropped
 * (task §5, SERVER-CONTRACT §6).
 */
export function paramsHash(request: ChatRequest, provider: 'openai' | 'anthropic'): string {
  return sha256Hex(canonicalJson(projectRequest(request, provider)));
}
