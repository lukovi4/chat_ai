# Chat AI Tool Schema v1 (canonical portable dialect)

The closed, portable schema dialect for Tool `parameters` declarations
(V1_SPEC §5, ADR 0003). This is the only schema language accepted by the Dart
Core and by every backend in v1: a backend or provider adapter must consume
the same client dialect unchanged and must pass the shared corpus below
before support is declared.

## The dialect

- Tool `name` matches `^[A-Za-z0-9_-]{1,64}$`; names are unique within one
  frozen Bot Profile.
- `parameters` root is always `{ "type": "object", ... }`.
- Allowed keywords are only `type`, `description`, `enum`, `properties`,
  `required`, `additionalProperties` and `items`.
- Allowed scalar types are `string`, `number`, `integer`, `boolean` and
  `null`; compound types are `object` and `array`.
- Every object declares `properties`, lists **every** property name in
  `required`, and sets `additionalProperties: false`. A semantically optional
  value is represented as required-but-nullable with
  `"type": ["<one non-null type>", "null"]`.
- An array has exactly one `items` schema. `enum` contains JSON scalar values
  compatible with the declared scalar type; a nullable enum includes `null`.
  Nested objects/arrays recursively follow the same rules.
- Everything else is rejected in v1, including `$schema`, `$id`, `$ref`,
  `$defs`, `const`, `default`, `oneOf`, `anyOf`, `allOf`, `not`, conditional
  schemas, `pattern`, `format`, length/range/item-count constraints,
  `uniqueItems`, `patternProperties`, and schema-valued/true
  `additionalProperties`.

## Core validation

The Core validates declarations on `ChatSession` construction and
`botProfile` assignment; an invalid name, a duplicate name or an invalid
dialect throws `ArgumentError` (the setter leaves the old profile unchanged,
with no key/backend call). Every backend repeats validation as its own trust
boundary — the Firebase server template revalidates before idempotency
claim/provider dispatch (see the `chat_ai_firebase` SERVER-CONTRACT §7 for
the server-side enforcement details).

## The normative fixture corpus

One shared fixture corpus is normative: the repo-root
`test/contract_fixtures/tool_schema_v1/` contains accepted/rejected schemas
and valid/invalid argument instances — it is read in place and never copied.
The Dart validator, every backend validator (the TypeScript BFF of the
Firebase server template included) and every provider translator MUST
produce the same verdict for every fixture. A future provider adapter must
pass the same corpus before release.
