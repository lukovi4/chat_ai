// App-owned composition root for the DEDICATED OpenAI-only smoke deployment.
// A thin wiring layer: it initializes Firebase Admin for THIS deployment's own
// project, reads mandatory deployment parameters + the OpenAI secret, builds the
// injected dependencies and hands them to the package-owned `createChatHandler`.
// It never re-implements the request pipeline or a second HTTP/SSE mapper.
//
// The OpenAI key lives only in Secret Manager (`OPENAI_API_KEY`); it is never in
// code, args, client config or git. Auth + App Check stay enforced inside the
// package handler regardless of the gen2 invoker IAM.

import { getApps, initializeApp } from 'firebase-admin/app';
import { getAppCheck } from 'firebase-admin/app-check';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { defineInt, defineSecret, defineString } from 'firebase-functions/params';
import { onRequest } from 'firebase-functions/v2/https';
import OpenAI from 'openai';

import { createChatHandler, type ChatServerDependencies, type ChatHttpHandler } from './server';
import { createSmokeHooks } from './smoke/hooks';

// The OpenAI key — Secret Manager only.
const OPENAI_API_KEY = defineSecret('OPENAI_API_KEY');

// Mandatory deployment parameters — no permissive package defaults. The model is
// a deployment choice, never a package default.
const OPENAI_MODEL = defineString('OPENAI_MODEL');
const CHAT_BOT_ID = defineString('CHAT_BOT_ID');
const REPLAY_BUCKET = defineString('REPLAY_BUCKET');
const MAX_OUTPUT_TOKENS = defineInt('MAX_OUTPUT_TOKENS');
const RATE_MAX_REQUESTS = defineInt('RATE_MAX_REQUESTS');
const RATE_WINDOW_SECONDS = defineInt('RATE_WINDOW_SECONDS');
const DAILY_ATTEMPT_QUOTA = defineInt('DAILY_ATTEMPT_QUOTA');
// The deployment region — no default, so a value is mandatory at deploy (an
// empty/absent region fails closed). Co-locate the Function, Firestore and the
// replay bucket in this region (see DEPLOY_SMOKE.md).
const FUNCTION_REGION = defineString('FUNCTION_REGION');

// The owner window and its onRequest timeout MUST be the same positive integer.
const FUNCTION_TIMEOUT_SECONDS = 300;
const REPLAY_TTL_SECONDS = 600;

// Initialize Firebase Admin once for this deployment's own project.
if (getApps().length === 0) initializeApp();

function positiveInt(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive safe integer`);
  }
  return value;
}

function requiredString(value: string, name: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
  return value;
}

// Build the package handler once, lazily, from runtime parameters/secrets.
let cachedHandler: ChatHttpHandler | null = null;
function buildHandler(): ChatHttpHandler {
  if (cachedHandler !== null) return cachedHandler;

  const botId = requiredString(CHAT_BOT_ID.value(), 'CHAT_BOT_ID');
  const model = requiredString(OPENAI_MODEL.value(), 'OPENAI_MODEL');
  const bucketName = requiredString(REPLAY_BUCKET.value(), 'REPLAY_BUCKET');
  const maxOutputTokens = positiveInt(MAX_OUTPUT_TOKENS.value(), 'MAX_OUTPUT_TOKENS');
  const rateMaxRequests = positiveInt(RATE_MAX_REQUESTS.value(), 'RATE_MAX_REQUESTS');
  const rateWindowSeconds = positiveInt(RATE_WINDOW_SECONDS.value(), 'RATE_WINDOW_SECONDS');
  const dailyAttemptQuota = positiveInt(DAILY_ATTEMPT_QUOTA.value(), 'DAILY_ATTEMPT_QUOTA');

  const firestore = getFirestore();
  const bucket = getStorage().bucket(bucketName);

  // SDK retries MUST be zero under the idempotency layer (the factory re-checks).
  const openaiClient = new OpenAI({ apiKey: OPENAI_API_KEY.value(), maxRetries: 0 });

  const deps: ChatServerDependencies = {
    hooks: createSmokeHooks(firestore, {
      botId,
      model,
      maxOutputTokens,
      rateMaxRequests,
      rateWindowSeconds,
      dailyAttemptQuota,
    }),
    auth: getAuth(),
    appCheck: getAppCheck(),
    firestore,
    bucket,
    // The one tier id (CHAT_BOT_ID) maps to the one configured OpenAI client.
    openAIClients: new Map([[botId, openaiClient]]),
    functionTimeoutSeconds: FUNCTION_TIMEOUT_SECONDS,
    replayTtlSeconds: REPLAY_TTL_SECONDS,
  };
  cachedHandler = createChatHandler(deps);
  return cachedHandler;
}

/**
 * The deployable OpenAI-only smoke Cloud Function `chat` (Functions gen2,
 * runtime `nodejs24` via firebase.json). Deployed to the mandatory
 * `FUNCTION_REGION`; `timeoutSeconds` equals the factory
 * `functionTimeoutSeconds`; only `OPENAI_API_KEY` is secret-bound.
 */
export const chat = onRequest(
  { region: FUNCTION_REGION, secrets: [OPENAI_API_KEY], timeoutSeconds: FUNCTION_TIMEOUT_SECONDS },
  async (req, res) => {
    await buildHandler()(req, res);
  },
);
