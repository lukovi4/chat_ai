// The single composition point of the server template: the concrete
// per-deployment dependencies the app-owned `src/index.ts` (a later increment)
// passes into `createChatHandler` (docs/server-template.md «Ownership and
// composition boundary»; SERVER-CONTRACT §4). Everything here is INJECTED — the
// handler never touches global/default Firebase Admin state, reads no API key
// and constructs no provider client.
//
// The Firebase/GCS/OpenAI dependencies are the official concrete SDK types (no
// bespoke AuthVerifier/FirestoreRepository/StorageRepository indirection).

import type OpenAI from 'openai';
import type { Auth } from 'firebase-admin/auth';
import type { AppCheck } from 'firebase-admin/app-check';
import type { Firestore } from 'firebase-admin/firestore';
import type { Storage } from 'firebase-admin/storage';

import type { ChatServerHooks } from './hooks';

/**
 * A private Cloud Storage bucket, exactly the concrete `Bucket` returned by the
 * Firebase Admin `Storage.bucket()` (re-exported from `@google-cloud/storage`);
 * referenced via `ReturnType` so no second storage package is a direct
 * dependency.
 */
export type ReplayBucket = ReturnType<Storage['bucket']>;

/**
 * Configured provider clients, one per tier from `config/tiers`, keyed by
 * `Tier.id` (docs/server-template.md). Each client is constructed by the app
 * with `maxRetries: 0`; the factory verifies that invariant. This increment
 * dispatches only `Tier.provider === "openai"`.
 */
export type OpenAIClientRegistry = ReadonlyMap<string, OpenAI>;

/**
 * The mandatory dependencies of `createChatHandler`. All are required and have
 * no package defaults; a missing dependency/hook is a construction error.
 */
export interface ChatServerDependencies {
  /** The four required business hooks (see {@link ChatServerHooks}). */
  hooks: ChatServerHooks;
  /** Concrete Firebase Admin Auth instance (id-token verification). */
  auth: Auth;
  /** Concrete Firebase Admin App Check instance (App Check verification). */
  appCheck: AppCheck;
  /** Concrete Firestore instance (idempotency/usage coordination). */
  firestore: Firestore;
  /** Concrete private replay bucket (short-lived terminal SSE outcomes). */
  bucket: ReplayBucket;
  /** Configured OpenAI clients, one per tier id (see {@link OpenAIClientRegistry}). */
  openAIClients: OpenAIClientRegistry;
  /**
   * The exact positive-integer `timeoutSeconds` the app also passes to Firebase
   * Functions gen2 `onRequest`; it bounds the owner window (SERVER-CONTRACT §6).
   */
  functionTimeoutSeconds: number;
  /**
   * The logical terminal replay TTL in seconds (`expiresAt = terminalAt +
   * replayTtlSeconds`); a positive integer of at least the 30-second client
   * retry window (SERVER-CONTRACT §6, `600` recommended).
   */
  replayTtlSeconds: number;
}
