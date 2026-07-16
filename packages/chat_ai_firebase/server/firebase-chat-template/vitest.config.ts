import { defineConfig } from 'vitest/config';

// Unit + fixture suite for the contract foundation and the OpenAI translator.
// No network, no API key, no emulator: every test is a pure function over local
// deterministic fixtures and the shared Dart/TypeScript tool-schema corpus
// (../../../../test/contract_fixtures/tool_schema_v1, read directly — never
// copied).
export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    exclude: ['node_modules/**'],
  },
});
