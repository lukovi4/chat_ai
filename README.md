# chat_ai — инструкция по интеграции

Этот файл — **единственная пользовательская инструкция** по подключению и
использованию всего репозитория. Остальные документы нормативные, технические
или эксплуатационные (карта — в разделе 14) и инструкцией по интеграции не
являются.

Пакеты приватные, в pub.dev не публикуются и подключаются как `git:`
зависимости.

Статус: **OpenAI-only v1**, платформы **iOS и Android**. Anthropic — backlog.

---

## 1. Назначение репозитория

В репозитории четыре Dart-пакета.

| Пакет | Что это | Обязателен |
|---|---|---|
| `chat_ai` (корень) | Core текстового чата: `ChatSession`, модели, состояния, виджеты, контракты backend'ов | да |
| `chat_ai_firebase` | `FirebaseChatBackend` — connection-bound HTTP/SSE транспорт к BFF приложения; рядом поставляется deployable server template и Node `runChatReply` | нет |
| `chat_ai_openai_realtime` | `OpenAIRealtimeChatBackend` — прямой **текстовый** OpenAI Realtime **WebSocket** `ChatBackend` | нет |
| `chat_ai_openai_realtime_voice` | `OpenAIRealtimeVoiceSession` — отдельная optional speech-to-speech **WebRTC**-сессия | нет |

Что важно понимать сразу:

- **один `ChatSession` использует ровно один текстовый `ChatBackend`** — Core
  сам транспорт не выбирает и не переключает;
- **voice-пакет подключается дополнительно**, рядом с текстовым backend'ом: он
  **не** реализует `ChatBackend`, **не** передаётся в `ChatSession` и живёт
  своим жизненным циклом;
- текстовый Realtime — это **WebSocket**, не WebRTC: ни микрофона, ни
  медиатреков, ни нативной аудиозависимости;
- voice Realtime — это **WebRTC**: микрофон, аудиотрек ассистента и канал
  событий.

`chat_ai` не зависит ни от Firebase, ни от Dio, ни от WebRTC — транспорт всегда
приходит из отдельного пакета или из реализации приложения.

---

## 2. Выбор варианта интеграции

| Вариант | Dart-пакеты | Где живут provider credentials | Кто выполняет tool-loop | Переживает ли reply закрытие клиента | Что приложение реализует само |
|---|---|---|---|---|---|
| **Firebase connection-bound text** | `chat_ai` + `chat_ai_firebase` | `OPENAI_API_KEY` в Secret Manager Firebase-проекта приложения | `ChatSession` (Core); `onToolCall` — приложения | нет | деплой server template, четыре production hooks, Auth/App Check, tier→model |
| **Direct Realtime WebSocket text** | `chat_ai` + `chat_ai_openai_realtime` | стандартный OpenAI API key — на backend приложения; на устройство попадает только эфемерный client secret | `ChatSession` (Core); `onToolCall` — приложения | нет | endpoint выпуска client secrets, `ClientSecretProvider`, лимиты и spend protection |
| **App-owned durable text backend** | `chat_ai` + собственная реализация `DurableChatBackend` **или** `ServerManagedDurableChatBackend` (опционально + Node `runChatReply` из `chat_ai_firebase/server`) | backend приложения | `DurableChatBackend` → Core; `ServerManagedDurableChatBackend` → сервер приложения | да — но только если приложение реально построило durable-инфраструктуру | весь durable-транспорт, Job, worker, store событий, replay, admission/quota/idempotency/retry (раздел 11) |
| **Optional voice** | `+ chat_ai_openai_realtime_voice` (рядом с любым текстовым вариантом) | эфемерный client secret; API key — на backend приложения | внутри voice-сессии: `onToolCall` приложения, если у профиля есть tools | нет — сессия живёт, пока жив клиент | mint endpoint, микрофонные разрешения и их UX, весь продуктовый UI |

Пакет **не поставляет** готовый production `DurableChatBackend` /
`ServerManagedDurableChatBackend` — см. раздел 11.

---

## 3. Граница ответственности

| Пакет | Flutter-приложение | Backend / worker приложения |
|---|---|---|
| `ChatSession` и `ConversationState` | хранение списка разговоров и самих `Conversation` | provider API key |
| сборка запроса (context assembly, trimming) | `checkpoint` — durable сохранение снапшота | деплой Firebase-проекта и функции |
| streaming-состояние и поток токенов | navigation и state management | маппинг tier → model / `maxOutputTokens` |
| механизм retry/idempotency по действующему контракту | инициализация Firebase | политика Auth / App Check |
| сериализация `Conversation` (`toJson`/`fromJson`) | Auth UI | hooks: entitlement, rate limit, quota |
| предобработка изображений (resize/JPEG) | локализованные строки (в т.ч. текст ошибок) | выпуск эфемерных Realtime client secrets |
| client-owned tool-loop в обычном режиме | image picker и full-screen viewer | app tools в server-managed режиме |
| виджеты `ChatMessageList` / `MessageBubble` / `ChatInputBar` | реализации Tool'ов (`onToolCall`) | durable Job, worker, store и доставка событий |
| интерфейсы backend'ов (`ChatBackend`, `DurableChatBackend`, `ServerManagedDurableChatBackend`) | реализация `ClientSecretProvider` | admission, quota, idempotency и retry вокруг `runChatReply` |
| Firebase-транспорт (`FirebaseChatBackend`) | выбор `BotProfile` | |
| Realtime-транспорты (текст и voice) | создание и lifecycle `ChatSession` | |
| Node `runChatReply` | | |

Пакет описывает **слой и владельца настройки**, а не конкретные файлы
приложения: где именно приложение хранит разговоры, как называет свои экраны и
чем реализует хранилище — его решение.

---

## 4. Установка

Все пакеты живут в одном репозитории и подключаются **одним и тем же полным
40-символьным commit SHA**. Ветка, тег или сокращённый SHA недопустимы: внутри
репозитория пакеты ссылаются друг на друга относительным `path:`, который Pub
разрешает в полный SHA, и другое описание источника ломает version solving.

Вместо `<full-40-character-commit-sha>` интегратор подставляет SHA того commit'а
пакета, который у него утверждён к использованию, — **один и тот же во всех
зависимостях этого репозитория**.

**Core + Firebase:**

```yaml
dependencies:
  chat_ai:
    git:
      url: https://github.com/lukovi4/chat_ai.git
      ref: <full-40-character-commit-sha>
  chat_ai_firebase:
    git:
      url: https://github.com/lukovi4/chat_ai.git
      ref: <full-40-character-commit-sha>
      path: packages/chat_ai_firebase

  # Приложение само импортирует и инициализирует Firebase:
  # chat_ai_firebase намеренно не зависит от firebase_core напрямую.
  firebase_core: ^4.12.1
  firebase_auth: ^6.5.6
  firebase_app_check: ^0.4.5+2
```

**Core + текстовый OpenAI Realtime:**

```yaml
dependencies:
  chat_ai:
    git:
      url: https://github.com/lukovi4/chat_ai.git
      ref: <full-40-character-commit-sha>
  chat_ai_openai_realtime:
    git:
      url: https://github.com/lukovi4/chat_ai.git
      ref: <full-40-character-commit-sha>
      path: packages/chat_ai_openai_realtime
```

**Optional voice** — подключается вместе со своими зависимостями из того же
SHA (`chat_ai` и `chat_ai_openai_realtime`, чей `ClientSecretProvider` он
переиспользует):

- при **Firebase text**-варианте приложение сохраняет `chat_ai_firebase` и
  **дополнительно** добавляет `chat_ai_openai_realtime` +
  `chat_ai_openai_realtime_voice`;
- при **Realtime text**-варианте `chat_ai_openai_realtime` уже подключён —
  добавляется только `chat_ai_openai_realtime_voice`.

```yaml
dependencies:
  chat_ai:
    git:
      url: https://github.com/lukovi4/chat_ai.git
      ref: <full-40-character-commit-sha>
  chat_ai_openai_realtime:
    git:
      url: https://github.com/lukovi4/chat_ai.git
      ref: <full-40-character-commit-sha>
      path: packages/chat_ai_openai_realtime
  chat_ai_openai_realtime_voice:
    git:
      url: https://github.com/lukovi4/chat_ai.git
      ref: <full-40-character-commit-sha>
      path: packages/chat_ai_openai_realtime_voice
```

Voice-пакет приносит `flutter_webrtc` (жёстко закреплённая версия) и iOS-плагин
опциональной записи — объявлять их отдельно не нужно.

Дальше — `flutter pub get`. Сгенерированные `*.freezed.dart` / `*.g.dart` уже
лежат в пакете: `build_runner` в приложении запускать не нужно.

Импорты:

```dart
import 'package:chat_ai/chat_ai.dart';                                // всегда
import 'package:chat_ai_firebase/chat_ai_firebase.dart';              // вариант 1
import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart'; // вариант 2
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart'; // optional voice

import 'package:chat_ai/testing.dart';                                // только тесты
```

---

## 5. Базовое подключение ChatSession

```dart
import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_firebase/chat_ai_firebase.dart';
import 'package:flutter/material.dart';

// 1. Транспорт — ровно одна строка; всё остальное от него не зависит.
final backend = FirebaseChatBackend(
  'https://<region>-<project>.cloudfunctions.net/chat',
);

// 2. Профиль бота: id — это server tier id, а не имя модели.
const profile = BotProfile(
  id: 'assistant',
  systemPrompt: 'You are a concise, helpful assistant.',
  tools: [],
);

// 3. Persistence приложения: Core ждёт его перед каждым потенциально платным
//    запросом, которым владеет сам (раздел 10).
Future<void> saveConversation(Conversation snapshot) async {
  await myStore.write(jsonEncode(snapshot.toJson()));
}

// 4. Одна сессия = один открытый Conversation.
final session = ChatSession(
  backend: backend,
  botProfile: profile,
  history: restoredConversation, // null — новый разговор
  checkpoint: saveConversation,  // null только для намеренно эфемерного чата
);

// 5. Готовые виджеты (композитного экрана пакет не поставляет).
Widget buildChat() => Column(
  children: [
    Expanded(
      child: ChatMessageList(
        session: session,
        failureText: localizeFailure, // локализация — приложения
      ),
    ),
    SafeArea(
      top: false,
      child: ChatInputBar(session: session, hint: 'Сообщение…'),
    ),
  ],
);

// 6. Команда и завершение.
await session.send('Привет');
await session.dispose();
```

Что нужно понимать про эту схему:

- **одна `ChatSession` = один открытый `Conversation`**; другой разговор — это
  `dispose()` старой сессии и создание новой с её историей;
- **Future команды не ждёт завершения генерации** — он завершается на решении
  «отправлено / no-op / отклонено»;
- **терминальный результат наблюдается через `states`** (`Done`, `Failed`,
  `Cancelled`), а накопленный видимый текст — через `tokens`; виджеты
  подписываются сами;
- **provider key никогда не находится на устройстве** — ни в коде, ни в
  `dart-define`, ни в нативной конфигурации.

Ключевые параметры конструктора: `backend`, `botProfile`, `onToolCall`,
`history`, `trimBudget` (по умолчанию выключен), `maxToolTurns` (5),
`retryDeadline` (30 с), `imageOptions` (2048 px / JPEG 85 / до 4 изображений),
`checkpoint`. Точные значения и инварианты — в [V1_SPEC.md](V1_SPEC.md),
поведение виджетов — в [docs/widgets-spec.md](docs/widgets-spec.md).

Что именно бросается, а что приходит данными:

- **исходы stream'а `send` / `startReply` / `admitReply` представлены
  `BackendEvent`** —
  операционный сбой провайдера или транспорта приходит как событие и попадает в
  `ConversationState`; stream errors из этого потока выходить не должны;
- **ошибки валидации и программные ошибки бросаются** согласно API: неверная
  числовая или tool-конфигурация — `ArgumentError` (сюда же относится
  `ServerManagedDurableChatBackend` вместе с ненулевым `checkpoint`), неверная
  восстановленная история — `FormatException`, команда после `dispose()` —
  `StateError`;
- **неизвестный статус `attachReply` намеренно пробрасывается** из
  `ChatSession.open`, чтобы Core не нормализовал потенциально живой reply.

---

## 6. Настройка Firebase-варианта

`FirebaseChatBackend` — **connection-bound** транспорт: один `POST` на каждый
`send()`-leg с ответом в виде SSE. Отмена подписки = обрыв соединения. Сам по
себе он **не является durable backend'ом** (раздел 11).

**Flutter:**

1. Создать/настроить Flutter-приложения (iOS/Android) в Firebase-проекте
   приложения и добавить app-owned нативную Firebase-конфигурацию или
   сгенерированный `firebase_options.dart`. **Пакет не поставляет никакой
   Firebase project configuration.**
2. `Firebase.initializeApp(...)` до создания живой сессии — пакет Firebase не
   инициализирует и `firebase_core` напрямую не тянет.
3. `FirebaseAppCheck.instance.activate(...)` с **production**-провайдерами
   (debug-провайдеры — только для smoke-харнесса).
4. Авторизация через Firebase Auth: id-token читается на каждый запрос.
   Анонимный вход допустим, только если это соответствует политике продукта.
5. Передать URL задеплоенной функции в `FirebaseChatBackend(url)` — это вся
   публичная поверхность настройки транспорта.

```dart
WidgetsFlutterBinding.ensureInitialized();
await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
await FirebaseAppCheck.instance.activate(
  providerAndroid: const AndroidPlayIntegrityProvider(),
  providerApple: const AppleAppAttestWithDeviceCheckFallbackProvider(),
);
```

**Server:**

1. Скопировать `packages/chat_ai_firebase/server/firebase-chat-template` в
   Firebase-проект приложения (одна копия на приложение: свой ключ, свой
   billing).
2. Положить `OPENAI_API_KEY` в Secret Manager — и только туда.
3. Настроить tier для того `BotProfile.id`, который шлёт приложение: `model`,
   `maxOutputTokens`.
4. Опционально задать `reasoningEffort` и `compactThreshold` этого tier.
5. Заменить smoke-композицию на **четыре production hooks**:
   `checkEntitlement`, `checkRateLimit`, `reserveQuota`, `settleQuota`.
6. Настроить Firestore (idempotency + TTL), приватный replay bucket и IAM.
7. Задеплоить endpoint и передать его URL в `FirebaseChatBackend`.

Явно:

- **`reasoningEffort` — настройка server-side tier**, не клиента;
- если она задана, provider получает `reasoning: { effort: ... }` в каждом
  запросе этого tier (включая каждый leg server-side tool loop);
- если не задана, запрос уходит **без** ключа `reasoning`;
- **`compactThreshold` — тоже настройка server-side tier**, не клиента: это
  единственное, что задаёт приложение для встроенного OpenAI Compact. Если
  значение задано, каждый запрос этого tier уходит с автоматическим
  `context_management: [{ type: "compaction", compact_threshold: ... }]`; если
  не задано, ключа `context_management` в запросе нет и Compact выключен.
  Значение должно быть **положительным safe integer**; сам порог и поддержку
  выбранной моделью проверяет владелец deployment — allowlist моделей в пакете
  нет;
- **Compact и обрезку истории реализует сам пакет**: proxy возвращает compact
  state как обычный `ProviderOpaquePart`, `FirebaseChatBackend` перестаёт
  отправлять историю старше последнего compact item, а server отправляет
  OpenAI только последний compact item и всё, что после него. Отдельного
  `/responses/compact`, нового поля Firestore или указателя в приложении нет;
- **с автоматическим Compact у `FirebaseChatBackend` нужно оставить
  `ChatSession.trimBudget: null`** — это значение по умолчанию. Текущий
  локальный newest-that-fit trimming нельзя включать одновременно с Compact:
  Core выполняет его до backend и целыми Message, поэтому может удалить
  Message с последним Compact item ещё до того, как backend найдёт границу.
  Совместного режима `trimBudget` + Compact нет;
- **актуальный продуктовый контекст по-прежнему формирует приложение**: system
  prompt, память и текущие продуктовые данные приложение продолжает добавлять
  в текущий контекст. Compact сжимает историю, но не заменяет контекст,
  который приложение обязано передать;
- Compact относится **только** к пути OpenAI Responses/Firebase и Node runner;
  OpenAI Realtime и voice-пакеты он не затрагивает;
- **smoke hooks не являются production policy** — это композиция для
  выделенного одноразового smoke-проекта;
- `FirebaseChatBackend` connection-bound и **сам по себе не durable backend**.

Технические контракты сервера: [SERVER-CONTRACT.md](packages/chat_ai_firebase/docs/SERVER-CONTRACT.md),
[server-template.md](packages/chat_ai_firebase/docs/server-template.md),
[README шаблона](packages/chat_ai_firebase/server/firebase-chat-template/README.md).

---

## 7. Настройка текстового Realtime-варианта

```dart
class MyClientSecretProvider implements ClientSecretProvider {
  @override
  Future<String> getClientSecret({required String botId}) async {
    // Запрос к СВОЕМУ backend'у: он держит стандартный OpenAI API key и
    // выпускает короткоживущий эфемерный client secret.
    return myBackend.mintRealtimeClientSecret(botId: botId);
  }
}

final backend = OpenAIRealtimeChatBackend(
  clientSecretProvider: MyClientSecretProvider(),
  model: 'gpt-realtime-2.1',                     // опционально; значение по умолчанию
  maxOutputTokens: 4096,                          // опционально; 1…4096
  responseIdleTimeout: const Duration(seconds: 60), // опционально
);

final session = ChatSession(backend: backend, botProfile: profile);
```

Явно:

- это **прямой текстовый WebSocket** к OpenAI Realtime — не WebRTC, без
  микрофона и медиатреков;
- **стандартный OpenAI API key остаётся только на backend приложения** — на
  устройство он не попадает никогда;
- **`ClientSecretProvider` приложения получает только `botId`** — не сам
  провайдер OpenAI, а именно этот колбэк, и он не видит ни `ChatRequest`, ни
  system prompt, ни сообщения, ни изображения, ни tools;
- **backend приложения выпускает свежий непустой эфемерный secret** через
  `POST /v1/realtime/client_secrets` — по одному на каждый `send()`-leg;
- **пакет не предоставляет endpoint выпуска client secrets** — это backend
  приложения;
- **`model` в `OpenAIRealtimeChatBackend` должен совпадать с той моделью, к
  которой mint endpoint привязывает credential**: client secret не является
  механизмом закрепления модели;
- **server replay / idempotency слоя здесь нет**: `idempotencyKey` в OpenAI не
  уходит и ничего не дедуплицирует;
- **уже выполненный inference не становится бесплатным после disconnect** —
  ни таймаут, ни отмена не отменяют то, что провайдер успел посчитать.

Подробная transport/money/platform-семантика — в
[README адаптера](packages/chat_ai_openai_realtime/README.md).

---

## 8. Optional voice

**Обязательная platform configuration.** Voice-сессия захватывает микрофон, и
без этих записей `getUserMedia` не пройдёт. Набор минимальный — ровно для
audio-only (`audio: true, video: false`) на закреплённом `flutter_webrtc 1.5.2`.

iOS — `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Продуктовый текст приложения: зачем ему микрофон.</string>
```

Android — `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
```

- `CAMERA` и `uses-feature` камеры **не добавлять**: пакет видео не захватывает,
  и плагин запрашивает `CAMERA` только при `video: true`.
- `INTERNET` нужен именно в `main`-манифесте: шаблон Flutter кладёт его только в
  `debug`/`profile`.
- `RECORD_AUDIO` — runtime-разрешение; его запрашивает сам плагин при старте
  захвата, но продуктовый UX запроса — приложения.
- Bluetooth-маршрутизация не требуется для работы: `BLUETOOTH` /
  `BLUETOOTH_ADMIN` (`android:maxSdkVersion="30"`) добавляются только если
  приложение само хочет BT-устройства.

```dart
final voice = OpenAIRealtimeVoiceSession(
  clientSecretProvider: MyClientSecretProvider(), // тот же контракт, что и в тексте
  botProfile: profile,
  mode: OpenAIRealtimeVoiceMode.singleTurn,       // или .conversation
);

voice.states.listen((state) => debugPrint('${state.phase}'));

await voice.start();   // ровно один раз на экземпляр
// …
await voice.stop();
await voice.dispose();
```

Явно:

- это **отдельная stateful WebRTC-сессия**: один экземпляр = одна сессия, без
  retry, reconnect и продления;
- она **не реализует `ChatBackend`**;
- она **не передаётся в `ChatSession`**;
- её можно использовать **рядом** с текстовым backend'ом;
- **приложение отвечает** за выпуск эфемерного secret'а, за микрофонные
  разрешения и их UX и за весь продуктовый UI.

Расширенные режимы, транскрипты, локальная запись, guardrail и ограничения —
технический reference:
[README voice-пакета](packages/chat_ai_openai_realtime_voice/README.md).

---

## 9. Tools

Tool'ы — это возможности приложения. **Пакет не поставляет ни одного бизнес-
инструмента**; он передаёт декларации провайдеру и маршрутизирует вызовы.

```dart
const searchNotesTool = Tool(
  name: 'search_notes',
  description: 'Searches the signed-in user notes.',
  parameters: {
    'type': 'object',
    'properties': {'query': {'type': 'string'}},
    'required': ['query'],
    'additionalProperties': false,
  },
);

Future<ToolResult> resolveTool(ToolCall call) async {
  final matches = await notesRepository.search(call.args['query'] as String);
  return ToolResult(content: jsonEncode(matches), isError: false);
}

final session = ChatSession(
  backend: backend,
  botProfile: const BotProfile(
    id: 'assistant',
    systemPrompt: 'Use search_notes when the user asks about saved notes.',
    tools: [searchNotesTool],
  ),
  onToolCall: resolveTool,
  checkpoint: saveConversation,
);
```

Кто выполняет tool-loop:

| Backend | Владелец tool-loop | Клиентский `onToolCall` |
|---|---|---|
| обычный `ChatBackend` | `ChatSession` / Core | вызывается; обязателен при непустых `tools` |
| `DurableChatBackend` | `ChatSession` / Core (тоже client-owned) | вызывается; обязателен при непустых `tools` |
| `ServerManagedDurableChatBackend` | сервер приложения | **не вызывается**; профиль с tools допустим без резолвера |
| Node `runChatReply` | сервер приложения | вызывается его собственный server-side `onToolCall` |

Правила:

- схема декларации — закрытый диалект
  [Chat AI Tool Schema v1](docs/TOOL-SCHEMA-V1.md); имена и схемы проверяются
  при создании сессии и при присваивании профиля;
- неизвестное имя, невалидные аргументы и исключение резолвера превращаются в
  санитизированный `isError`-результат — текст исключения провайдеру не уходит;
- **выполнение Tool'а гарантированно at-least-once**: для side-effecting
  Tool'ов приложение обязано **дедуплицировать по `ToolCall.id`** перед самим
  побочным эффектом.

---

## 10. Persistence и lifecycle

- **Сохранение.** Приложение хранит `session.snapshot` как
  `Conversation.toJson()` и восстанавливает через `Conversation.fromJson(...)`.
  У `Conversation` нет id базы — ключ и запись принадлежат приложению.
- **`checkpoint`.** Вызывается после создания/обновления Message и
  idempotency-ключа. Провалившийся checkpoint запрос не выпускает. Что именно
  он покрывает, зависит от backend'а:
  - обычный `ChatBackend` и `DurableChatBackend` — Core дожидается checkpoint
    **перед каждым потенциально платным запросом, которым владеет сам** (первый
    leg, tool-leg, единственный fresh-key fallback); admission здесь
    **двухшаговый**: checkpoint, затем `startReply`;
  - `ServerManagedDurableChatBackend` — Dart-checkpoint **запрещён**:
    `ChatSession` и `ChatSession.open` бросают `ArgumentError` синхронно, до
    любого обращения к backend'у. Снапшот сохраняет сам сервер — атомарно
    вместе с Job внутри единственного
    `admitReply(replyId, request, snapshot)` (раздел 11), поэтому ключ первого
    leg фиксируется там же и разрыва «Messages сохранены, Job не создан» не
    существует. Последующие server-owned legs фиксирует приложение на своём
    сервере — через awaited `runChatReply.onLegStart`.
- **Обычный конструктор.** Нормализует «зависшие» статусы восстановленной
  истории: `sending → failed`, `streaming → interrupted`, и проверяет
  инварианты схемы v1. Это безусловное поведение конструктора.
- **`ChatSession.open(...)`.** Тот же набор параметров, но асинхронный, и нужен
  **только** для durable attach: при наличии durable backend'а и последнего
  `streaming`-ассистента он ровно один раз спрашивает `attachReply`. Есть
  стрим — reply жив и наблюдение продолжается без нового запроса; `null` —
  обычная нормализация; исключение — ничего не нормализуется, сессия не
  создаётся.
- **`dispose()`.** Освобождает ресурсы, отменяет подписки и backoff, дожидается
  teardown, закрывает потоки. Идемпотентен; команда после `dispose()` — это
  `StateError`.
- **`cancel()`.** Останавливает генерацию для пользователя: `Cancelled`,
  видимый partial сохраняется, поздние события игнорируются.
- **detach ≠ cancel** для durable backend'а:
  - `dispose()` активного reply **только отсоединяет наблюдение** и `cancelReply`
    не вызывает — удалённая операция может продолжаться;
  - **терминальный `BackendEvent`** (`done` / `error`) завершает сам reply и
    наблюдение за ним — и тоже **не** вызывает `cancelReply`; после терминала
    удалённая генерация уже не идёт;
  - удалённую отмену запрашивает **только явный `cancel()`**.
- **Remote cancel — не более одного раза на один logical reply.** Повторный
  `cancel()` того же reply ничего не добавляет; следующий reply той же сессии
  отменяется отдельно и полноценно.

---

## 11. Durable-режим без ложных обещаний

**Пакет НЕ поставляет готовый production `DurableChatBackend` или
`ServerManagedDurableChatBackend`.** Их нет ни в одном из четырёх пакетов.

Пакет поставляет ровно три вещи:

1. **два Dart-контракта** — `DurableChatBackend` и
   `ServerManagedDurableChatBackend`;
2. **поддержку start-или-admit / attach / cancel в `ChatSession`**
   (`ChatSession.open`, detach vs remote cancel, замена partial'а при replay);
3. **Node `runChatReply`** — выполнение одного полного server-side logical
   reply.

Всё остальное приложение обязано построить и соединить самостоятельно:

- транспорт start-или-admit / attach / cancel;
- atomic admission (в server-managed режиме — одна транзакция
  «сохранить snapshot + создать Job»);
- Job (запись о reply);
- worker host, в котором reply реально выполняется;
- store событий и самого reply;
- replay наблюдаемого текста;
- admission;
- quota;
- idempotency;
- политику retry / restart;
- отмену.

Два режима различаются владельцем tool-loop:

Это **два независимых контракта**: `ServerManagedDurableChatBackend` **не**
наследует `DurableChatBackend` — оба лишь `implements ChatBackend`.

**`DurableChatBackend`** (двухшаговый, не изменён)

- **tool-loop принадлежит Core**;
- admission — **два шага**: Dart-`checkpoint`, затем `startReply`;
- `startReply` запускает **один leg**; следующий leg — снова `startReply` с тем
  же `replyId` и новым checkpoint'нутым `attemptKey`.

**`ServerManagedDurableChatBackend`** (одношаговый admission)

- **сервер владеет всем logical reply**, включая tools и все provider legs;
- вместо `startReply` — `admitReply(replyId, request, snapshot)`, вызываемый
  **ровно один раз** на logical reply:
  - `replyId` — id пустого `streaming`-ассистента,
  - `request` — замороженный запрос **первого leg**,
  - `snapshot` — точный замороженный `Conversation` (user Message + этот
    пустой ассистент), зафиксированный до обработки событий reply;
- backend приложения обязан **одной серверной транзакцией** сохранить этот
  snapshot и создать (или безопасно присоединиться к) единственный Job этого
  `replyId`; provider нельзя запускать до commit;
- `accepted` — расписка об этом commit'е: первое успешное событие стрима,
  означающее, что транзакция Messages + Job зафиксирована; повторная
  транспортная доставка того же admission не создаёт второй Job;
- ошибка до `accepted` допустима только как **подтверждённый отказ** admission
  (Job не создан, provider не запускался) — неопределённый сетевой исход
  сначала разрешается по `replyId` и отказом считаться не может;
- Core различает две одинаковые на вид pre-token ошибки по `accepted`:
  - **до `accepted`** — отказ: пустой assistant удаляется, user становится
    `failed`, recovery — `resend` под тем же (непотраченным) ключом;
  - **после `accepted`, но до первой delta** — admission уже committed: пустой
    assistant удаляется, user остаётся `sent`, терминал —
    `Failed(..., FailurePhase.sending)`, recovery — `regenerate`;
  - **после видимой delta** — как везде: partial сохраняется в `interrupted`
    assistant, `Failed(..., FailurePhase.streaming)`, recovery — `regenerate`;
- `replyId` admits **не более одного раза**, поэтому два вида «повторного
  admission» не смешиваются: тот же `replyId` — это транспортный дубль, который
  join'ит существующий Job; explicit `regenerate()` — это **новый logical
  reply** с новым `attemptKey` и новым `replyId` (предыдущий ответ уходит из
  активной ветки). Recover-before-rebill в этом режиме не применяется; для
  обычного и client-owned durable он не изменён;
- `cancelReply` обязан быть идемпотентным и race-safe с незавершённым
  admission: cancel после `admitReply`, но до `accepted`, не теряется;
- отдельный Dart-`checkpoint` в этом режиме **запрещён** (`ArgumentError`);
- наблюдаемый stream содержит только `accepted` / `delta` / `done` / `error`;
- профиль с tools допустим без клиентского `onToolCall`;
- саму atomic-транзакцию, Job, store и admission endpoint реализует
  **приложение** — пакет по-прежнему не поставляет production durable backend.

Про Node `runChatReply` (`packages/chat_ai_firebase/server/firebase-chat-template`,
импорт из `src/runner`):

- `firstAttemptKey` — **уже сохранённый ключ первого leg**; он передаётся
  неизменным и `onLegStart` для нулевого leg не вызывается;
- `onLegStart` вызывается **только для следующих legs** и awaited до вызова
  провайдера;
- runner **не предоставляет** Firebase, storage, Job API, admission, quota,
  idempotency и crash recovery;
- `createChatHandler` остаётся **отдельным connection-bound HTTP/SSE
  handler'ом** и durable-режимом не является;
- **runner и Dart durable-интерфейсы не соединены готовым wire-адаптером** —
  как события reply доходят до клиента, решает приложение.

---

## 12. Testing

`FakeChatBackend` из `package:chat_ai/testing.dart` прогоняет настоящий Core
без транспорта, сети и платных вызовов:

```dart
import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai/testing.dart';

test('reply reaches Done', () async {
  final fake = FakeChatBackend()..reply('Hello from the fake.');
  final session = ChatSession(backend: fake, botProfile: profile);

  final terminal = session.states.firstWhere((state) => state is Done);
  await session.send('Hello');
  await terminal;

  await session.dispose();
});
```

Тестовая точка входа экспортирует ровно две сценарные заглушки —
`FakeChatBackend` и `FakeDurableChatBackend`. Полный каталог их методов и
нормативные правила — в [V1_SPEC.md](V1_SPEC.md) §10 и в самом
`lib/testing.dart`. Server-managed режим проверяется тестовым двойником
приложения: такой заглушки пакет не поставляет.

---

## 13. Что пакет не делает

- база данных, список разговоров и навигация приложения;
- UI авторизации, подписок и paywall;
- production business policy (entitlement, quota, rate limit);
- бизнес-инструменты (tools);
- provider secrets на устройстве;
- автоматическая production durable-инфраструктура;
- cursor-based resume по `streamId` / `eventId`;
- web и desktop;
- Anthropic в v1.

---

## 14. Карта остальных документов

| Документ | Назначение | Аудитория |
|---|---|---|
| **README.md** (этот файл) | единственная инструкция интегратора | разработчик приложения |
| [V1_SPEC.md](V1_SPEC.md) | нормативный публичный контракт: API, значения по умолчанию, инварианты | разработчик приложения и пакета |
| [docs/CONTEXT.md](docs/CONTEXT.md) | терминология и доменная модель | разработчик пакета |
| [docs/TOOL-SCHEMA-V1.md](docs/TOOL-SCHEMA-V1.md) | нормативная Tool Schema и её корпус фикстур | обе стороны |
| [docs/widgets-spec.md](docs/widgets-spec.md) | точный контракт виджетов | разработчик приложения |
| [SERVER-CONTRACT.md](packages/chat_ai_firebase/docs/SERVER-CONTRACT.md), [WIRE-FORMATS.md](packages/chat_ai_firebase/docs/WIRE-FORMATS.md) | wire и server contract Firebase-варианта | тот, кто реализует сервер |
| [server-template.md](packages/chat_ai_firebase/docs/server-template.md) | ownership и композиция серверного шаблона | тот, кто деплоит шаблон |
| [DEPLOY_SMOKE.md](packages/chat_ai_firebase/server/firebase-chat-template/DEPLOY_SMOKE.md), [example README](packages/chat_ai_firebase/example/README.md) | только smoke-проверка на устройстве | сопровождение пакета |
| [docs/adr/](docs/adr/) | причины принятых решений | сопровождение пакета |
| [CHANGELOG.md](CHANGELOG.md) | история изменений | обе стороны |

README package'ей (`packages/*/README.md`) — технические reference'ы своих
транспортов, а не вторые инструкции по интеграции.

---

## Кодогенерация и платформы

Модели используют `freezed` / `json_serializable`. Сгенерированные файлы
закоммичены и входят в git-зависимость — приложению `build_runner` не нужен.
Только сопровождающие пакета после изменения модели запускают:

```sh
dart run build_runner build --delete-conflicting-outputs
```

Платформы v1: iOS 18+, Android 14 (API 34)+. Web и desktop не поддерживаются.
