// HTTP/SSE transport glue (SERVER-CONTRACT §2/§3/§5, task §4/§11). The handler
// signature matches the Firebase Functions gen2 HTTP handler: it receives a
// gen2 request (an `http.IncomingMessage` carrying the raw body) and an express
// `http.ServerResponse`. Typing against the Node `http` types keeps the
// dependency surface minimal while remaining exactly what `onRequest` provides
// in the app-owned composition root (a later increment) — `onRequest(handler)`
// stays assignable. No provider, no Firebase state here.

import type { IncomingMessage, ServerResponse } from 'node:http';

import type { WireCause } from '../core/wire';

/** The gen2 request: an incoming message plus the parsed raw body buffer. */
export type ChatHandlerRequest = IncomingMessage & { rawBody: Buffer };
/** The gen2 response (express `Response` is an `http.ServerResponse`). */
export type ChatHandlerResponse = ServerResponse;
/** The package-owned handler wrapped by `onRequest` in the app composition root. */
export type ChatHttpHandler = (
  req: ChatHandlerRequest,
  res: ChatHandlerResponse,
) => Promise<void>;

/** 10 MB raw request payload ceiling (SERVER-CONTRACT §3/§10). */
export const MAX_PAYLOAD_BYTES = 10 * 1024 * 1024;

const KEEPALIVE_MS = 15_000;

/** A mapped pre-stream failure: HTTP status + wire cause (+ detail/retry). */
export interface PreStreamError {
  status: number;
  cause: WireCause;
  detail?: string;
  retryAfterMs?: number;
}

/** Reads a single-valued request header (Node lowercases header names). */
export function header(req: ChatHandlerRequest, name: string): string | undefined {
  const value = req.headers[name];
  return typeof value === 'string' ? value : undefined;
}

/** Extracts the bearer token from an `Authorization` header, or `null`. */
export function parseBearer(authorization: string | undefined): string | null {
  if (authorization === undefined) return null;
  const match = /^Bearer (.+)$/i.exec(authorization);
  if (match === null) return null;
  const token = match[1]!.trim();
  return token.length > 0 ? token : null;
}

/**
 * Emits a pre-stream JSON failure `{cause, detail?}` with the mapped status; a
 * `retryAfterMs` becomes the standard `Retry-After` header (seconds, task §11).
 * The detail is always a stable sanitized string — never body/token/provider
 * content.
 */
export function sendPreStreamError(res: ChatHandlerResponse, error: PreStreamError): void {
  if (res.headersSent || res.writableEnded) return;
  res.statusCode = error.status;
  res.setHeader('Content-Type', 'application/json');
  if (error.retryAfterMs !== undefined) {
    res.setHeader('Retry-After', String(Math.ceil(error.retryAfterMs / 1000)));
  }
  const body: Record<string, unknown> = { cause: error.cause };
  if (error.detail !== undefined) body.detail = error.detail;
  res.end(JSON.stringify(body));
}

/**
 * SSE connection writer: sets the streaming headers, emits a `: ping` after
 * every 15 s of outgoing silence (keepalive comments are never stored in the
 * replay object), and detects a dead connection through a failed write.
 */
export class SseWriter {
  private keepalive: ReturnType<typeof setTimeout> | null = null;
  private headersOpen = false;
  private ended = false;
  disconnected = false;
  /**
   * Invoked exactly once the first time a write (a normal frame OR a keepalive)
   * reveals a dead connection. The owner wires this to its unified disconnect so
   * a failed keepalive aborts the provider without waiting for the next event.
   */
  onDisconnect?: () => void;

  constructor(private readonly res: ChatHandlerResponse) {}

  /** Opens the `200` SSE headers exactly once and starts keepalive. */
  openHeaders(): void {
    if (this.headersOpen) return;
    this.headersOpen = true;
    this.res.statusCode = 200;
    this.res.setHeader('Content-Type', 'text/event-stream');
    this.res.setHeader('Cache-Control', 'no-cache, no-transform');
    this.res.setHeader('X-Accel-Buffering', 'no');
    this.res.setHeader('X-Chat-AI-Wire-Version', '1');
    this.res.flushHeaders();
    this.scheduleKeepalive();
  }

  /** Writes one normalised frame; resets keepalive silence; reports success. */
  writeFrame(frame: string): boolean {
    const ok = this.rawWrite(frame);
    if (ok) this.scheduleKeepalive();
    return ok;
  }

  private rawWrite(chunk: string): boolean {
    if (this.disconnected || this.ended || this.res.writableEnded) return false;
    try {
      // The boolean result of `write` is backpressure, NOT a disconnect; only a
      // throw means the connection is dead.
      this.res.write(chunk);
      return true;
    } catch {
      this.disconnected = true;
      this.clearKeepalive();
      this.onDisconnect?.();
      return false;
    }
  }

  private scheduleKeepalive(): void {
    this.clearKeepalive();
    const timer = setTimeout(() => {
      if (this.rawWrite(': ping\n\n')) this.scheduleKeepalive();
    }, KEEPALIVE_MS);
    timer.unref?.();
    this.keepalive = timer;
  }

  private clearKeepalive(): void {
    if (this.keepalive !== null) {
      clearTimeout(this.keepalive);
      this.keepalive = null;
    }
  }

  /** Marks the connection dead (observed disconnect) and stops keepalive. */
  markDisconnected(): void {
    this.disconnected = true;
    this.clearKeepalive();
  }

  /** Ends the response once, clearing the keepalive timer. */
  end(): void {
    this.clearKeepalive();
    if (this.ended) return;
    this.ended = true;
    if (!this.res.writableEnded) {
      try {
        this.res.end();
      } catch {
        /* connection already gone */
      }
    }
  }
}
