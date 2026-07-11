# Серверный шаблон (BFF) — спецификация

> Шаблон объявлен частью кита в ADR 0001 («deployed fresh per Consuming App»).
> Wire-поведение — в `SERVER-CONTRACT.md`; здесь зафиксированы платформа,
> служебные схемы, обязательные hooks и deploy-gates.

## Платформа

**Firebase Cloud Functions gen2 (Node/TypeScript) + Firestore + private Google
Cloud Storage bucket.** Firestore координирует Attempt и usage; GCS временно
держит только завершённый нормализованный SSE outcome для idempotency replay
(ADR 0006). Долговременной server-side истории разговоров нет.

Cloud Functions gen2 остаётся платформой v1. Deploy validation обязана доказать,
что для каждого tier его `maxOutputTokens` и максимальный служебный overhead
нормализованного SSE (включая `provider_state`) укладываются в **10 MB streaming
response limit** платформы. Непроходящий tier не деплоится; миграция на отдельный
Cloud Run и новый продуктовый лимит в v1 не добавляются.

## Обязательный pipeline одного запроса

1. Firebase Auth id-token и App Check.
2. `wireVersion == 1`, JSON/schema и payload ≤ 10 MB. Ошибка здесь не создаёт
   idempotency/usage запись и не вызывает провайдера.
3. Firestore lookup/claim `idempotency/{uid}/keys/{attemptKey}`.
4. Известный ключ: `running` → ждать terminal, `complete` → проверить и replay
   GCS-объект, `aborted` → 410. Live join/replay не выполняет новых rate/quota
   операций. Единственное исключение: stale-running recovery повторно вызывает
   `reserveQuota({kind:"getExisting", uid, attemptKey})` как идемпотентное чтение уже существующей
   reservation, затем закрывает тот же ledger как `unknown`.
5. Новый owner: `checkEntitlement → checkRateLimit → reserveQuota(createOrGet)`.
   `reserveQuota(createOrGet, attemptKey)` атомарно создаёт или возвращает тот же usage/quota
   ledger — отдельного crash-gap «reservation уже есть, usage ещё нет» нет.
6. Затем вызывается выбранный provider adapter.
7. Завершение обновляет тот же ledger и вызывает идемпотентный
   `settleQuota`; replay не создаёт дубликатов. Ошибка settlement оставляет
   ledger в `unknown`, логируется и не отбрасывает уже replayable ответ.

Provider-generation rate limit никогда не стоит перед recovery join/replay.
Исключение admission/reserve hook отображается в `upstream`; deny — соответственно в
`entitlement`, `rate` или `quota`.
Любой выход до provider dispatch доказанно `unbilled`: provisional claim
удаляется, а уже созданная reservation освобождается; stale `running` не остаётся.
Если процесс упал после reserve и точный исход неизвестен, stale recovery
получает тот же ledger и `reservationId` повторным идемпотентным
`reserveQuota(getExisting, attemptKey)`, собирает прежний `QuotaReservation` и закрывает его
как `unknown`; новая reservation не создаётся.

## Typed hooks (обязательный контракт деплоя)

```ts
type Tier = {
  id: string;
  provider: "openai" | "anthropic";
  model: string;
  maxOutputTokens: number;
};

type EntitlementResult =
  | { kind: "allowed"; tier: Tier }
  | { kind: "denied"; detail?: string };

type RateLimitResult =
  | { kind: "allowed" }
  | { kind: "denied"; retryAfterMs?: number; detail?: string };

type QuotaReservation = { attemptKey: string; reservationId: string };
type ReserveQuotaRequest =
  | { kind: "createOrGet"; uid: string; attemptKey: string;
      botId: string; tier: Tier }
  | { kind: "getExisting"; uid: string; attemptKey: string };
type ReserveQuotaResult =
  | { kind: "reserved"; reservation: QuotaReservation }
  | { kind: "denied"; detail?: string };

type Usage = { inputTokens: number | null; outputTokens: number | null };
type QuotaOutcome =
  | { kind: "billed"; usage: Usage }
  | { kind: "unbilled" }
  | { kind: "estimated"; usage: Usage }
  | { kind: "unknown" };

checkEntitlement(uid: string, botId: string): Promise<EntitlementResult>;
checkRateLimit(uid: string, botId: string): Promise<RateLimitResult>;
reserveQuota(request: ReserveQuotaRequest): Promise<ReserveQuotaResult>;
  // idempotent by attemptKey: createOrGet atomically creates/reuses the ledger;
  // getExisting is the stale-recovery read and MUST NOT create a reservation
settleQuota(
  reservation: QuotaReservation,
  outcome: QuotaOutcome,
): Promise<void>;               // idempotent by attemptKey
```

Все четыре hooks обязательны. Отсутствующий hook, молчаливый allow или
неидемпотентные reserve/settle — ошибка deploy validation. `unknown` никогда не
освобождает reservation. Бизнес-математика quota/rate остаётся кодом конкретного
приложения; универсальный quota engine в кит не добавляется.

Идемпотентность здесь — один ledger на `attemptKey`: duplicate reserve/settle в
том же состоянии является no-op. После доказанного `unbilled` safe-release
same-key retry может перевести **тот же** ledger `unbilled → reserved`; новая
reservation/usage-строка не создаётся. Других reopen-переходов нет.

## Firestore (минимальные схемы)

```text
idempotency/{uid}/keys/{key}       // uid в пути — security boundary
  status: "running" | "complete" | "aborted"
  runId: string                    // fresh UUID для каждого unknown→running
  requestHash: string               // provisional canonical input hash для
                                    // running до entitlement/provider resolution
  provider: "openai" | "anthropic" | null // frozen до quota/provider dispatch
  paramsHash: string | null         // SHA-256 canonical provider-effective JSON:
                                   // wireVersion и message id/status/createdAt/
                                   // attemptKey удалены; matching opaque включён,
                                   // foreign-provider opaque удалён
  outcomeObjectPath: string | null // только complete
  outcomeSha256: string | null     // только complete
  outcomeBytes: number | null      // только complete
  createdAt: timestamp
  terminalAt: timestamp | null
  expiresAt: timestamp | null      // только terminal; default +10 мин

usage/{uid}/attempts/{attemptKey}
  uid, attemptKey, botId, provider, model
  reservationId: string
  status: "running" | "terminal"
  inputTokens: number | null
  outputTokens: number | null
  quotaOutcome: "billed" | "unbilled" | "estimated" | "unknown" | null
  aborted: bool
  createdAt: timestamp
  terminalAt: timestamp | null

config/tiers/{tierId}
  provider: "openai" | "anthropic"
  model: string
  maxOutputTokens: number
```

`running` не имеет `expiresAt`. Наблюдатель после
`createdAt + deployedFunctionTimeout` атомарно переводит stale `running` в
`aborted` и отвечает 410. На каждом чтении `expiresAt <= now` логически означает
`unknown`, независимо от задержки Firestore TTL; TTL только физически убирает
terminal metadata.

До resolution повтор сравнивает `requestHash` и join-ит owner. После resolution
он вычисляет projection по **сохранённому** `provider` и сравнивает `paramsHash`;
смена tier-конфига не меняет живой Attempt. `provider/paramsHash` записываются до
quota reserve/provider dispatch и обязательны на terminal.

## Replay bucket

```text
chat-replays/{uid}/{key}/{runId}.sse
```

- bucket private, Public Access Prevention включён; доступ только у service
  account функции по минимально необходимой IAM-роли;
- lifecycle policy обязательна и удаляет orphan/expired объекты; логический TTL
  всё равно проверяется по Firestore до чтения;
- каждый unknown→running получает новый `runId`; object create использует
  `ifGenerationMatch: 0`. Cleanup удаляет только exact path старого runId и не
  может снести replay более нового исполнения того же key;
- успешный terminal: дописать `done|tool_call` в объект → finalize → проверить
  bytes/SHA-256 → Firestore `complete` → только затем отдать terminal клиенту;
- safe-release/post-claim admission exit: записать в объект текущего `runId`
  единственный нормализованный `error` с `cause/detail/retryAfterMs`, finalize,
  settlement `unbilled`, затем удалить idempotency claim. Object metadata
  фиксирует `outcomeKind: "release"` и SHA-256;
- joiner сохраняет присоединённый `runId`. Увидев удаление claim, он читает
  exact run-object и возвращает тот же error/Retry-After; owner не меняется и
  provider внутри этого HTTP-запроса не перезапускается. Только следующий
  backend request клиента может claim-ить новый `runId`;
- если release-object не finalise-ится, claim не удаляется: Attempt становится
  `aborted`, joiner получает 410/`upstream`, provider повторно не вызывается;
- ошибка object/final commit: не отдавать success terminal, Attempt → `aborted`,
  клиенту `error(upstream)` либо EOF; joiner не читает незавершённый объект;
- replay сверяет path/bytes/SHA-256. Permanent missing/corrupt object атомарно
  переводит `complete → aborted` и отвечает 410: provider под старым key не
  вызывается, но explicit recovery получает разрешённый fresh-key fallback.

## Provider adapters и safe release

- Оба official SDK создаются с `maxRetries: 0` (или точным zero-retry параметром
  pinned версии). Ни один 5xx/timeout не повторяется под idempotency-слоем.
- OpenAI: **Responses API**, `store:false`, без `previous_response_id` и
  background mode; reasoning continuity возвращается через encrypted opaque
  items.
- Anthropic: **Messages API**, `anthropic-version: 2023-06-01`; thinking и
  redacted-thinking blocks сохраняются без изменений.
- `safeRelease` — закрытая per-adapter таблица: pinned OpenAI retryable
  rate-limit 429 (но не insufficient-quota/credit), Anthropic
  `429 rate_limit_error` и `529 overloaded_error`, плюс connect failure до нуля
  записанных request bytes. Fixtures пинят точную структуру; неизвестный вариант
  fail-closed в `aborted`.
- Generic `500/502/504`, unknown `5xx`, reset/timeout после записи байтов всегда
  `aborted`. DNS/TCP/TLS до нуля записанных request bytes может release.

## Deploy validation (fail closed)

До публикации функции проверяются:

1. все hooks реализованы и проходят idempotency contract tests;
2. каждый tier имеет provider/model/maxOutputTokens, а модель поддерживает
   vision, streaming, function calling, strict Tool schemas и stateless
   opaque-state round-trip;
   worst-case normalized SSE укладывается в 10 MB streaming response;
3. OpenAI/Anthropic API family/version и translator goldens совпадают с
   `SERVER-CONTRACT.md`;
4. parallel tool calls отключены; Tool declarations/args проходят закрытый
   Chat AI Tool Schema v1 dialect из SERVER-CONTRACT §7; TypeScript validator и
   оба translators проходят тот же `test/contract_fixtures/tool_schema_v1/`
   corpus, что Dart Core;
5. Firestore TTL настроен только на terminal `expiresAt`;
6. replay bucket private, IAM/service account и lifecycle policy корректны;
7. SDK retries равны нулю; `safeRelease` не содержит wildcard status family;
   cross-instance joiner fixture получает тот же release cause/retryAfter и
   делает ноль provider calls;
8. function timeout, SSE headers/keepalive и `X-Chat-AI-Wire-Version: 1`
   настроены.

## Деплой под новое приложение

1. Firebase project приложения с Auth/App Check.
2. Provider secrets в Secret Manager.
3. `config/tiers` и четыре обязательных hooks.
4. Firestore indexes/TTL и private replay bucket lifecycle/IAM.
5. Contract tests + deploy validation, затем deployed disconnect smoke.

Свой ключ, свой billing, свой usage-log и короткий replay store — один BFF на
Consuming App (ADR 0001/0006).
