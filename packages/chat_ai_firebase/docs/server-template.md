# Серверный шаблон (BFF) — спецификация

> Шаблон объявлен частью кита в ADR 0001 («deployed fresh per Consuming App»).
> Wire-поведение — в `SERVER-CONTRACT.md`; здесь зафиксированы платформа,
> служебные схемы, обязательные hooks и deploy-gates.

**Provider scope v1: только OpenAI Responses.** Anthropic adapter перенесён в
product backlog и не является v1 acceptance criterion. Значение `anthropic`
остаётся зарезервированным в persisted/internal типах, но v1 не устанавливает
SDK, не выполняет dispatch и fail-closed отклоняет такой tier.

Каталог шаблона — **`server/firebase-chat-template/`**: reusable Firebase
Functions gen2 TypeScript-**шаблон** BFF, копируемый и разворачиваемый в
Firebase-проект каждого consuming app после того, как приложение добавит свой
composition root, secrets и project. Сам по себе он **не является** самостоятельно
deployable проектом (текущий статус increment'а — в README шаблона). У него
**собственные `package.json` / `package-lock.json`** (lockfile **отслеживается** —
деплоится как app, не публикуется как библиотека); `.firebaserc`, project ID,
secrets, service-account / admin keys и бизнес-правила приложения **не
поставляются** с шаблоном (только per-deployment).

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
  provider: "openai" | "anthropic"; // v1: openai; anthropic reserved backlog
  model: string;
  maxOutputTokens: number;
  reasoningEffort?: Exclude<ReasoningEffort, null>; // OpenAI SDK type
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
  | { kind: "denied"; detail?: string }
  | { kind: "terminal" };  // createOrGet only (see below)

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

`ReserveQuotaResult.terminal` — типизированный результат **только для
`createOrGet`** (никогда для `getExisting`, который остаётся settlement-recovery
read и возвращает reservation). Он означает: durable usage ledger для этого
`attemptKey` уже имеет terminal не-`unbilled` outcome (`billed | estimated |
unknown`), поэтому повторный provider-dispatch запрещён — даже если
idempotency/replay metadata уже истекли и был создан provisional owner claim.
Handler на `terminal` не вызывает provider и не вызывает `settleQuota`
(accounting уже terminal), не делает safe release и не удаляет claim (это снова
сделало бы ключ пригодным для запуска), best-effort переводит provisional claim в
`aborted` tombstone и возвращает pre-stream `410 {cause:"upstream",
detail:"attempt-terminal"}`. Единственный terminal ledger, который может снова
стать `running`, — `unbilled`; `denied` остаётся именно quota denial и
отображается в `429`. Это состояние не кодируется через `denied.detail` или иные
строковые соглашения.

## Firestore (минимальные схемы)

```text
idempotency/{uid}/keys/{key}       // uid в пути — security boundary
  status: "running" | "complete" | "aborted"
  runId: string                    // fresh UUID для каждого unknown→running
  requestHash: string               // provisional canonical input hash для
                                    // running до entitlement/provider resolution
  provider: "openai" | "anthropic" | null // v1 writes openai; anthropic reserved
  paramsHash: string | null         // SHA-256 canonical provider-effective JSON:
                                   // wireVersion и message id/status/createdAt/
                                   // attemptKey удалены; matching opaque включён,
                                   // foreign-provider opaque удалён
  outcomeObjectPath: string | null // только complete
  outcomeSha256: string | null     // только complete
  outcomeBytes: number | null      // только complete
  createdAt: timestamp
  terminalAt: timestamp | null
  expiresAt: timestamp | null      // только terminal; + replayTtlSeconds

usage/{uid}/attempts/{attemptKey}
  uid, attemptKey, botId, provider, model
  reservationId: string
  status: "running" | "terminal"
  inputTokens: number | null
  outputTokens: number | null
  quotaOutcome: "billed" | "unbilled" | "estimated" | "unknown" | null
  createdAt: timestamp
  terminalAt: timestamp | null

config/tiers/{tierId}
  provider: "openai" | "anthropic" // v1 deployment allows openai only
  model: string
  maxOutputTokens: number
```

Usage ledger не дублирует lifecycle-состояние Attempt `aborted`. Единственный
авторитетный источник `running | complete | aborted` — idempotency-запись;
usage ledger отвечает только за reservation, usage и quota settlement. Это
исключает рассинхронизацию, когда quota уже settled, а финализация replay позже
переводит Attempt в `aborted`.

`running` не имеет `expiresAt`. Наблюдатель после
`createdAt + functionTimeoutSeconds` атомарно переводит stale `running` в
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

- v1 поставляет только OpenAI adapter. Official OpenAI SDK создаётся с
  `maxRetries: 0`; ни один 5xx/timeout не повторяется под idempotency-слоем.
- OpenAI: **Responses API**, `store:false`, без `previous_response_id` и
  background mode; reasoning continuity возвращается через encrypted opaque
  items.
- `reasoningEffort` — необязательная настройка server-side tier. Если она
  задана, каждый provider request этого tier (включая каждый leg server-side
  tool loop) получает `reasoning: { effort: <reasoningEffort> }`. Если она не
  задана, OpenAI получает прежний request без ключа `reasoning`. Поддержка
  конкретного значения зависит от выбранной модели (контракт OpenAI/provider
  configuration), локальной валидации значений нет.
- Future/backlog, не v1: Anthropic Messages adapter с сохранением
  thinking/redacted-thinking blocks.
- `safeRelease` — закрытая per-adapter таблица: pinned OpenAI retryable
  rate-limit 429 (но не insufficient-quota/credit) плюс connect failure до нуля
  записанных request bytes. Fixtures пинят точную структуру; неизвестный вариант
  fail-closed в `aborted`. Будущий provider adapter обязан добавить собственную
  точную allowlist до включения поддержки.
- Generic `500/502/504`, unknown `5xx`, reset/timeout после записи байтов всегда
  `aborted`. DNS/TCP/TLS до нуля записанных request bytes может release.

## Deploy validation (fail closed)

До публикации функции проверяются:

1. все hooks реализованы и проходят idempotency contract tests;
2. каждый tier имеет provider/model/maxOutputTokens, а модель поддерживает
   vision, streaming, function calling, strict Tool schemas и stateless
   opaque-state round-trip;
   worst-case normalized SSE укладывается в 10 MB streaming response;
3. OpenAI API family/version и translator goldens совпадают с
   `SERVER-CONTRACT.md`; Anthropic не является v1 deploy option;
4. parallel tool calls отключены; Tool declarations/args проходят закрытый
   Chat AI Tool Schema v1 dialect из SERVER-CONTRACT §7; TypeScript validator и
   OpenAI translator проходит тот же канонический corpus из корня репозитория
   (`test/contract_fixtures/tool_schema_v1/`), что Dart Core; будущий adapter
   обязан пройти его до релиза;
5. Firestore TTL настроен только на terminal `expiresAt`;
6. replay bucket private, IAM/service account и lifecycle policy корректны;
7. SDK retries равны нулю; `safeRelease` не содержит wildcard status family;
   cross-instance joiner fixture получает тот же release cause/retryAfter и
   делает ноль provider calls;
8. `functionTimeoutSeconds` совпадает с `timeoutSeconds` функции;
   `replayTtlSeconds >= 30`; SSE headers/keepalive и
   `X-Chat-AI-Wire-Version: 1` настроены.

## Ownership and composition boundary

Этот раздел канонизирует одну схему композиции: что является обязательной
логикой пакета `chat_ai`, а что — настройками конкретного consuming app. Он не
меняет ни typed hooks (см. «Typed hooks (обязательный контракт деплоя)»), ни
deploy-gates (см. «Deploy validation (fail closed)»); он лишь фиксирует, **кто**
их поставляет и **как** они собираются. Это граница композиции, а не новый
wire/product-контракт: wire-форма из `SERVER-CONTRACT.md` не меняется.

### Обязательная логика пакета (приложение её не переписывает)

Server template реализует и поддерживает весь runtime-orchestration одного
запроса — это код пакета, а не приложения:

- HTTP/wire validation (`wireVersion == 1`, JSON/schema, payload ≤ 10 MB);
- Firebase Auth id-token и App Check verification;
- idempotency lookup/claim и весь lifecycle `running`/`complete`/`aborted`
  (join/replay/410) из «Обязательный pipeline одного запроса»;
- фиксированный admission order `checkEntitlement → checkRateLimit →
  reserveQuota(createOrGet)` только для нового owner;
- provider dispatch, `safeRelease` allowlist, строгий terminal commit order и
  replay-верификация path/bytes/SHA-256;
- идемпотентный settlement и единый usage/quota ledger.

Consuming app не переписывает и не отключает эту логику. Он поставляет только
per-deployment зависимости и бизнес-политику за обязательными точками
enforcement.

### Внутренняя factory-граница

Единственная точка композиции server template — внутренняя factory:

```ts
createChatHandler(dependencies)
```

Это **server-template internal API**, а не Flutter public API из `V1_SPEC.md` §3
и не новый wire/product-контракт из `SERVER-CONTRACT.md`.

Factory получает обязательный `ChatServerDependencies`:

- `hooks: ChatServerHooks`;
- `auth` — конкретный Firebase Admin **Auth** instance;
- `appCheck` — конкретный Firebase Admin **App Check** instance;
- `functionTimeoutSeconds` — фактический `timeoutSeconds` Firebase Function;
- `replayTtlSeconds` — логический TTL terminal Attempt/replay;
- Firestore instance;
- private replay bucket;
- registry настроенных provider clients (по одному на каждый tier из
  `config/tiers`).

`ChatServerHooks` содержит ровно четыре уже утверждённых hook — `checkEntitlement`,
`checkRateLimit`, `reserveQuota`, `settleQuota`. Их сигнатуры и результаты берутся
**без изменений** из «Typed hooks (обязательный контракт деплоя)»; этот раздел их
не переопределяет.

Auth и App Check verification выполняет **package-owned handler** — это часть
обязательной логики пакета (шаг 1 из «Обязательный pipeline одного запроса»), а не
приложения. Handler верифицирует id-token и App Check через **переданные**
`auth`/`appCheck` instances и **не** обращается к global/default Firebase Admin
state, так что скрытой зависимости от неявно инициализированного SDK нет. `auth` и
`appCheck` — конкретные official Firebase Admin SDK instances; собственных
`AuthVerifier`/`AppCheckVerifier` или иных framework-типов пакет не вводит.

`functionTimeoutSeconds` и `replayTtlSeconds` — обязательные app-owned
положительные целые значения без package defaults. Одно и то же значение
`functionTimeoutSeconds` передаётся в `createChatHandler` и в Firebase Functions
gen2 `onRequest({timeoutSeconds: ...})`: handler использует его как точную границу
owner window, поэтому расхождение запрещено и является deploy-validation error.
`replayTtlSeconds` определяет `expiresAt = terminalAt + replayTtlSeconds`, должен
быть не меньше 30-секундного client retry window; рекомендуемое значение для v1 —
`600` секунд. Выбор значения принадлежит приложению, применение TTL и запрет
слишком короткого значения — обязательные инварианты пакета.

Все зависимости обязательны и не имеют defaults. Отсутствующий dependency или
hook, равно как молчаливый allow-all вместо реального hook, — это
construction/deploy-validation error (см. «Deploy validation (fail closed)»).
Универсальный allow-all, условный или «no-op» hook в пакет не входит.

### Application-owned composition root (`src/index.ts`)

После копирования шаблона приложение создаёт собственный тонкий `src/index.ts` —
это **application-owned composition root**. Он:

- инициализирует Firebase Admin для своего Firebase project;
- получает от него конкретные `Auth` и `App Check` instances;
- выбирает обязательные `functionTimeoutSeconds` и `replayTtlSeconds`;
- получает Firestore и private replay bucket;
- создаёт provider SDK clients из Secret Manager;
- реализует четыре business hooks;
- передаёт `ChatServerDependencies` (включая `auth`/`appCheck`) в
  `createChatHandler`;
- оборачивает handler в Firebase Functions gen2 `onRequest`;
- выбирает имя экспортируемой Cloud Function;
- задаёт region, memory/concurrency и secret bindings, а для `onRequest`
  использует ровно тот же `functionTimeoutSeconds`, который передан factory;
- запускает обязательную deploy validation.

Канонический reusable template этого файла-композиции **не содержит**:

- Firebase project ID и `.firebaserc`;
- реальных secrets / API keys;
- service-account / admin credentials;
- тарифов, subscription model и quota-математики;
- имени Firebase project/resources и имени replay bucket;
- provider secrets и Cloud Function deployment settings.

Всё перечисленное — per-deployment и принадлежит приложению (это согласуется с
«не поставляются с шаблоном» из intro и «Not shipped» из README шаблона).

### Настройки принадлежат приложению, инварианты — нет

«Настройки принадлежат приложению» **не** означает, что приложение может
отключить обязательные safety/idempotency/accounting инварианты. Per-deployment
композиция обязана пройти package deploy validation (полный список — в «Deploy
validation (fail closed)»), в частности:

- присутствуют все четыре hooks и проходят idempotency contract;
- каждый tier имеет provider client;
- SDK retries отключены (`maxRetries: 0`);
- `functionTimeoutSeconds` положителен и точно совпадает с `onRequest`
  `timeoutSeconds`, ограничивая orphaned generation;
- `replayTtlSeconds` — положительное целое значение не меньше `30`;
- worst-case нормализованный SSE укладывается в 10 MB;
- replay bucket private и имеет требуемые IAM/lifecycle settings;
- Firestore TTL/indexes настроены по контракту.

Приложение выбирает значения (project, secrets, tiers, лимиты, region,
`functionTimeoutSeconds`, `replayTtlSeconds`), но не вправе снять сами gates.

### Test seam

Та же factory даёт естественный тестовый шов: `createChatHandler` принимает
in-memory/fake зависимости (test hooks, stub/mock `auth`/`appCheck` verifier
instances, fake Firestore/bucket, stub provider clients) для handler-тестов.
Поскольку handler использует **переданные** Auth/App Check instances, а не global
Firebase Admin state, contract tests подставляют stub-verifier'ы и не требуют сети,
реального Firebase project или настоящих токенов. Это следствие обязательной
инъекции зависимостей, а не отдельный DI-framework: дополнительных интерфейсов,
контейнеров или регистрационного слоя пакет не вводит.

## Connection-independent reply runner

`createChatHandler` остаётся connection-bound: его lifecycle привязан к HTTP
request/response, disconnect клиента вызывает `AbortController.abort()`.
Отдельно от него server template предоставляет **runner** — выполнение одного
полного логического reply без HTTP/SSE lifecycle и без Firebase:

```text
src/runner/index.ts   ← публичный Firebase-free barrel (импортировать отсюда)
src/runner/reply.ts   ← реализация; напрямую не импортировать
```

Runner — узкая композиция уже существующей provider-логики
(`buildOpenAIResponsesRequest`, `translateOpenAIStream`, `classifyOpenAIError`,
`hasZeroRetries`, `validateArgumentInstance`), а не framework. Он не импортирует
HTTP/SSE writer, Firebase Auth/App Check, Firestore, GCS replay, smoke hooks и
handler; он ничего не хранит, не генерирует `attemptKey`, не выполняет
admission/quota/idempotency и не делает retry. `createChatHandler` и его
pipeline остаются поведенчески неизменными — runner ничего в них не переписывает.

Публичная поверхность (полные сигнатуры — в `src/runner/index.ts`):

```ts
runChatReply({
  replyId,      // стабильная identity всего логического reply (владелец — app)
  request,      // уже провалидированный ChatRequest
  client,       // инжектированный OpenAI client, maxRetries: 0
  tier,         // { model, maxOutputTokens, reasoningEffort? }
  onLegStart,   // awaited граница ПЕРЕД каждым billable provider leg
  onEvent,      // упорядоченная awaited доставка NormalizedEvent + identity
  onToolCall,   // server-side tool loop приложения
  maxToolTurns, // default 5
  signal,       // единственный способ отменить выполнение
}): Promise<ChatReplyResult>
```

`ChatReplyResult` возвращает structured terminal (`done`, `provider-error` с
`cause`/`retryAfterMs`/`disposition`, `tool-loop-limit`, `cancelled`,
`local-error`, `sink-error`), накопленные assistant parts, per-leg записи
(`attemptKey`, `dispatched`, outcome, точный usage) и агрегированный usage.
Отсутствующий usage никогда не подменяется нулями: если хотя бы один
dispatched leg не вернул точный usage, суммы равны `null` и `exact: false`.

### Минимальная интеграция в app-owned worker

```ts
import { runChatReply } from './runner';

const result = await runChatReply({
  replyId,                       // из записи приложения о reply
  request,                       // прошёл существующую wire-валидацию
  client: openAIClient,          // ключ и клиент — приложения
  tier: { model, maxOutputTokens },
  signal: worker.signal,

  // Единственная точка, где приложение фиксирует billable leg ДО вызова
  // провайдера: создать/вернуть собственный attemptKey (UUID v4).
  onLegStart: async ({ replyId, legIndex, request }) => {
    const attemptKey = await store.beginLeg(replyId, legIndex, request);
    return { attemptKey };
  },

  // Персистентность потока — приложения; пакет ничего не пишет.
  onEvent: async ({ replyId, legIndex, attemptKey, event }) => {
    await store.appendEvent(replyId, legIndex, attemptKey, event);
  },

  // Tools — приложения; пакет не поставляет ни одного.
  onToolCall: async ({ toolCallId, name, args }) =>
    ({ content: await app.runTool(toolCallId, name, args) }),
});

await store.finishReply(replyId, result.termination, result.parts, result.usage);
```

Правила tool loop зеркалят Dart Core: без parallel tool calls, лимит по
`maxToolTurns` проверяется до callback и до следующего leg, имя вне declarations
даёт `unknown-tool`, непрошедшие `validateArgumentInstance` аргументы —
`invalid-tool-arguments`, бросок или невалидный результат callback —
`tool-execution-failed` (текст исключения провайдеру не передаётся), повторный
`toolCallId` переиспользует уже полученный результат.

### Что принадлежит приложению

- **worker host и его deployment** (процесс/сервис, где выполняется runner),
  **persistence**, **admission**, **quota**, **idempotency** и **retry policy** —
  всё это app-owned; пакет их не реализует и не предполагает конкретную
  инфраструктуру;
- **GCS replay bucket** из «Replay bucket» — короткоживущий terminal-артефакт
  HTTP-handler'а, а **не** live generation storage: runner его не использует;
- **smoke composition** (`src/smoke/`) — деплой-проверка, а **не** production
  backend;
- пакет **не поставляет durable backend implementation** для Flutter: Dart
  `DurableChatBackend` — это контракт, который реализует приложение;
- Dart durable capability и Node runner — **два независимых API**. Пакет не
  вводит новый wire, который связывал бы их напрямую: как события reply
  доходят до клиента, решает приложение.

## Деплой под новое приложение

1. Firebase project приложения с Auth/App Check.
2. Provider secrets в Secret Manager.
3. `config/tiers` и четыре обязательных hooks.
4. Firestore indexes/TTL и private replay bucket lifecycle/IAM.
5. Contract tests + deploy validation, затем deployed disconnect smoke.

Свой ключ, свой billing, свой usage-log и короткий replay store — один BFF на
Consuming App (ADR 0001/0006).
