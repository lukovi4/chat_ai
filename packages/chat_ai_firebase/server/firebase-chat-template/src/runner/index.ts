// The public, Firebase-free barrel of the connection-independent reply runner
// (docs/server-template.md «Connection-independent reply runner»). An app-owned
// worker imports the runner through THIS module — never from the
// implementation file — and gets no HTTP, Firebase, Firestore, GCS replay,
// smoke or handler dependency with it.

export { runChatReply, ChatReplyConfigurationError } from './reply';

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
} from './reply';
