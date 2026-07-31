# chat_ai_firebase

Firebase-часть кита `chat_ai`. Пакет содержит **не только** Flutter-транспорт:

- **Flutter barrel** экспортирует ровно один тип — `FirebaseChatBackend`
  (`lib/`); `chat_ai` он не реэкспортирует;
- **server template** — deployable Firebase Functions gen2 BFF
  (`server/firebase-chat-template/`), включая connection-independent reply
  runner `runChatReply`;
- **example/** — physical-device smoke harness.

> **Инструкция по интеграции — одна, и она в корне репозитория:**
> [README.md](../../README.md). Здесь только reference по этому пакету.

```dart
import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_firebase/chat_ai_firebase.dart';

final backend = FirebaseChatBackend(url);
final session = ChatSession(backend: backend, botProfile: profile);
```

## Транспорт

- `FirebaseChatBackend(url)` — один `POST` на каждый `send()` через `dio`
  (`ResponseType.stream`) к задеплоенному endpoint'у, SSE-ответ декодируется в
  `BackendEvent` ядра (V1_SPEC §8, `docs/SERVER-CONTRACT.md`).
- Каждый запрос несёт `Authorization: Bearer <id-token>` (`firebase_auth`) и
  `X-Firebase-AppCheck` (`firebase_app_check`), читаемые per request.
- Возвращаемый stream никогда не бросает: любой исход — отказ авторизации, HTTP
  статус, некорректное тело, обрыв — это `BackendEvent`.
- Отмена подписки = wire-cancel: pending HTTP future прерывается немедленно,
  соединение закрывается.
- Транспорт **connection-bound** и по контракту «глупая труба»: без retry и
  backoff (money-aware цикл живёт в ядре), без таймаутов и cancel-endpoint'а.
  Durable backend'ом он **не является**.

## Что принадлежит приложению

- **Инициализация Firebase.** Пакет никогда не вызывает
  `Firebase.initializeApp` и не зависит от `firebase_core` напрямую.
- **Provider key остаётся на сервере.** Устройство общается только с
  задеплоенным BFF (`server/firebase-chat-template/`); см. ADR 0001.

## Структура

- `lib/` — адаптер: `FirebaseChatBackend`, wire-энкодер и SSE-слои (внутренние,
  не экспортируются).
- `server/firebase-chat-template/` — deployable Firebase Functions BFF,
  владеющий серверной стороной `docs/SERVER-CONTRACT.md`, плюс `src/runner`.
- `example/` — physical-device smoke harness (Firebase + задеплоенный endpoint).
- `docs/` — server/wire contracts и Firebase-специфичные ADR (0001, 0006).

## Технические контракты

- [SERVER-CONTRACT.md](docs/SERVER-CONTRACT.md) — wire и правила прокси.
- [WIRE-FORMATS.md](docs/WIRE-FORMATS.md) — точные байтовые формы.
- [server-template.md](docs/server-template.md) — ownership и композиция
  шаблона, runner.
- [README шаблона](server/firebase-chat-template/README.md) — конкретный
  deployable template.
