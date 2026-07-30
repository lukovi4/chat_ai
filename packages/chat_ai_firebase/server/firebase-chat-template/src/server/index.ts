// Public surface of the package-owned server runtime: the internal composition
// factory and its dependency/hook contract (docs/server-template.md «Ownership
// and composition boundary»). This is server-template internal API — NOT Flutter
// public API and NOT a new wire contract. The app-owned `src/index.ts`
// composition root (a later increment) imports `createChatHandler` from here.

export { createChatHandler, ChatServerConfigError } from './handler';

export type {
  ChatServerDependencies,
  OpenAIClientRegistry,
  ReplayBucket,
} from './dependencies';

export type {
  ChatServerHooks,
  Tier,
  EntitlementResult,
  RateLimitResult,
  QuotaReservation,
  ReserveQuotaRequest,
  ReserveQuotaResult,
  Usage,
  QuotaOutcome,
} from './hooks';

export type { ChatHttpHandler, ChatHandlerRequest, ChatHandlerResponse } from './transport';

// The connection-independent reply runner, re-exported for one common server
// public surface. A detached worker should import `./runner` instead: this
// module also pulls the Firebase-bound HTTP handler.
export { runChatReply, ChatReplyConfigurationError } from '../runner';

export type {
  ChatReplyConfigurationErrorReason,
  ChatReplyEventDelivery,
  ChatReplyEventSink,
  ChatReplyLegContext,
  ChatReplyLegDispatch,
  ChatReplyLegOutcome,
  ChatReplyLegRecord,
  ChatReplyLegStart,
  ChatReplyResult,
  ChatReplyTermination,
  ChatReplyToolCall,
  ChatReplyToolHandler,
  ChatReplyToolResult,
  ChatReplyUsage,
  RunChatReplyOptions,
} from '../runner';
