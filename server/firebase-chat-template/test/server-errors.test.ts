import { describe, expect, it } from 'vitest';
import { APIError, APIConnectionError } from 'openai';

import { classifyOpenAIError } from '../src/server/openai';

// G. OpenAI error classification (task §9/§12G). STRUCTURED ONLY — status/code/
// headers, never `error.message` text.

function apiError(status: number, code: string | undefined, headers: Headers = new Headers()): APIError {
  const body = code === undefined ? {} : { code, message: 'ignored', type: 'x', param: null };
  return new APIError(status, body, 'ignored', headers);
}

describe('classifyOpenAIError — safe release allowlist', () => {
  it('a documented retryable 429 rate_limit_exceeded releases as rate with Retry-After', () => {
    const error = apiError(429, 'rate_limit_exceeded', new Headers({ 'retry-after': '2' }));
    expect(classifyOpenAIError(error)).toEqual({ cause: 'rate', disposition: 'release', retryAfterMs: 2000 });
  });

  it('reads retry-after-ms precisely when present', () => {
    const error = apiError(429, 'rate_limit_exceeded', new Headers({ 'retry-after-ms': '1500' }));
    expect(classifyOpenAIError(error)).toEqual({ cause: 'rate', disposition: 'release', retryAfterMs: 1500 });
  });

  it('a retryable 429 without a retry header still releases (no retryAfterMs)', () => {
    expect(classifyOpenAIError(apiError(429, 'rate_limit_exceeded'))).toEqual({ cause: 'rate', disposition: 'release' });
  });
});

describe('classifyOpenAIError — fail closed', () => {
  it('insufficient_quota is upstream + aborted (never released)', () => {
    expect(classifyOpenAIError(apiError(429, 'insufficient_quota'))).toEqual({ cause: 'upstream', disposition: 'aborted' });
  });

  it('a bare/unknown 429 is aborted', () => {
    expect(classifyOpenAIError(apiError(429, undefined))).toEqual({ cause: 'upstream', disposition: 'aborted' });
  });

  it('context_length_exceeded is context-too-long + aborted (not released)', () => {
    expect(classifyOpenAIError(apiError(400, 'context_length_exceeded'))).toEqual({
      cause: 'context-too-long',
      disposition: 'aborted',
    });
  });

  it.each([500, 502, 503, 504])('a %s server error is upstream + aborted', (status) => {
    expect(classifyOpenAIError(apiError(status, 'server_error'))).toEqual({ cause: 'upstream', disposition: 'aborted' });
  });

  it('an invalid provider key (401) is upstream + aborted', () => {
    expect(classifyOpenAIError(apiError(401, 'invalid_api_key'))).toEqual({ cause: 'upstream', disposition: 'aborted' });
  });

  it('a connection failure has no zero-byte proof → upstream + aborted', () => {
    expect(classifyOpenAIError(new APIConnectionError({ message: 'boom' }))).toEqual({
      cause: 'upstream',
      disposition: 'aborted',
    });
  });

  it('a non-SDK throw is aborted', () => {
    expect(classifyOpenAIError(new Error('SENTINEL'))).toEqual({ cause: 'upstream', disposition: 'aborted' });
  });
});
