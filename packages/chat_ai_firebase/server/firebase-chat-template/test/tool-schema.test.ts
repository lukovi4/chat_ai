import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

import {
  isValidToolSchema,
  validateArgumentInstance,
  validateToolset,
} from '../src/core/tool-schema';

// The ONE shared normative corpus (SERVER-CONTRACT §7). Read directly from the
// repo-root fixtures — never copied into a second directory. Dart, this
// validator and both provider translators must produce the same verdict for
// every case.
function loadCorpus(name: string): unknown {
  const url = new URL(`../../../../../test/contract_fixtures/tool_schema_v1/${name}`, import.meta.url);
  return JSON.parse(readFileSync(url, 'utf8'));
}

interface ToolCase {
  case: string;
  tools: Array<{ name: unknown; description?: unknown; parameters: unknown }>;
}
interface DeclarationsCorpus {
  accepted: ToolCase[];
  rejected: ToolCase[];
}
interface ArgumentCase {
  case: string;
  parameters: Record<string, unknown>;
  valid: unknown[];
  invalid: unknown[];
}
interface ArgumentsCorpus {
  cases: ArgumentCase[];
}

const declarations = loadCorpus('declarations.json') as DeclarationsCorpus;
const argumentsCorpus = loadCorpus('arguments.json') as ArgumentsCorpus;

describe('Chat AI Tool Schema v1 — declaration corpus parity', () => {
  it('the corpus is non-trivial (both verdicts present)', () => {
    expect(declarations.accepted.length).toBeGreaterThan(0);
    expect(declarations.rejected.length).toBeGreaterThan(0);
  });

  for (const c of declarations.accepted) {
    it(`accepts: ${c.case}`, () => {
      expect(validateToolset(c.tools)).toBe(true);
    });
  }

  for (const c of declarations.rejected) {
    it(`rejects: ${c.case}`, () => {
      expect(validateToolset(c.tools)).toBe(false);
    });
  }
});

describe('Chat AI Tool Schema v1 — argument-instance corpus parity', () => {
  it('the corpus is non-trivial', () => {
    expect(argumentsCorpus.cases.length).toBeGreaterThan(0);
  });

  for (const c of argumentsCorpus.cases) {
    describe(c.case, () => {
      it('the fixture parameters are a valid v1 schema', () => {
        expect(isValidToolSchema(c.parameters)).toBe(true);
      });
      c.valid.forEach((instance, index) => {
        it(`valid instance #${index}`, () => {
          expect(validateArgumentInstance(c.parameters, instance)).toBe(true);
        });
      });
      c.invalid.forEach((instance, index) => {
        it(`invalid instance #${index}`, () => {
          expect(validateArgumentInstance(c.parameters, instance)).toBe(false);
        });
      });
    });
  }
});

describe('Chat AI Tool Schema v1 — validator surface', () => {
  it('errors do not leak the schema/arguments payload', () => {
    // The public contract is boolean; there is no error taxonomy over it.
    expect(typeof validateToolset([])).toBe('boolean');
    expect(validateToolset([])).toBe(true); // empty toolset is trivially valid
  });
});
