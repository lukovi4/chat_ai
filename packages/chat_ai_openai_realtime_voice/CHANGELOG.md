# Changelog

All notable changes to `chat_ai_openai_realtime_voice`. This is a private,
unpublished git package; the version is not bumped in this increment.

## 0.1.0 (unreleased)

Universal Realtime voice engine increment — added to the same money-safe
(one-mint / one-signaling-POST / no-retry / no-reconnect / exactly-once teardown)
lifecycle, on top of the existing speech-to-speech session, optional final
transcripts, assistant transcript deltas, programmatic interrupt and iOS local
recording.

### Corrective P1 fix — round 5 (initial-history acknowledgement event)

**A session started with `initialConversation` still hung in `connecting` until
the timeout fired.** The seeding waited for a `conversation.item.created`, but
the current Realtime API answers a client `conversation.item.create` with
[`conversation.item.added`](https://developers.openai.com/api/reference/resources/realtime/server-events#conversation.item.added)
(followed by `conversation.item.done`); the real acknowledgement was therefore
ignored and every history item ended in the round-4 `responseIdleTimeout`
deadline as a terminal `session` failure (reproduced deterministically on
device). The seeding now waits for `conversation.item.added` — the **only**
acknowledgement: the legacy `conversation.item.created` and the trailing
`conversation.item.done` are not dispatched to the history wait and confirm
nothing. Nothing else changed: same wire format, same one-item-at-a-time
sequencing, same startup gate, same well-formed-`item.id` check, same
`responseIdleTimeout` deadline, same terminal-failure and cleanup behaviour, no
new public API and no new dependency.

### Corrective P1 fix — round 4 (bounded initial-history seeding)

**A session started with `initialConversation` hung in `connecting` forever.**
Each history item waited for an acknowledgement that never completed — no
timeout, no failure, the microphone never armed (reproduced deterministically on
device). The working hypothesis of this round was that the culprit was the
synthetic client-side `item.id` (`hist_<n>`) the wait had to match, which the
server was assumed not to echo back. **That hypothesis was later disproved**: a
subsequent physical smoke showed history failing identically before and after the
synthetic ids were removed. The actual cause was the protocol mismatch fixed in
round 5 above (the seeding listened for `conversation.item.created`, while the
current Realtime API answers with `conversation.item.added`). Round 4 therefore
did **not** fix the freeze; the two changes it made are kept as invariants, with
no new public API and no new dependency:

1. **No client-side id correlation.** No synthetic `item.id` is put on the wire
   any more (the server assigns the ids). History is still sent strictly one item
   at a time with the mic off and no `response.create`, so at most one
   acknowledgement can be outstanding: any well-formed acknowledgement arriving
   while an item is pending acknowledges it. A malformed event (no `item`, a
   non-Map `item`, a missing/empty/non-String `item.id`) still confirms nothing
   and the wait continues. This removed an unnecessary client-side assumption
   about server-assigned ids, but on its own it changed nothing observable.
2. **The wait is bounded.** Each acknowledgement is now bounded by the existing
   `responseIdleTimeout` (default 60 s, injectable clock). A lost ack is a
   terminal `session` failure: the mic never enables, the next item is never sent,
   there is no retry / reconnect / re-mint, exactly one teardown, and a late ack
   (after the timeout, a stop or a dispose) is inert. The deadline is cancelled on
   the ack, on a send failure, on the last item and on any stop / dispose /
   teardown. This is the change that carried real diagnostic value: it turned an
   indefinite freeze into a deterministic terminal `session` failure within 60 s,
   which is what exposed the round-5 protocol mismatch. It stays in place as a
   safety invariant against any future lost acknowledgement.

### Corrective P1 fixes — round 3 (gated-send ownership)

Two async-window race conditions closed. The prior round-2 ownership models
guarded the space BETWEEN operations but each left one window open DURING a
possibly-hung send:

1. **Tool operation ownership across the gated `function_call_output` send.** The
   operation's identity token is now held through the whole send sequence — it is
   no longer released before the output send. Ownership (session active, token
   still current, turn epoch unchanged) is re-checked immediately BEFORE
   `response.create`, so an interrupt / new valid user turn / stop / dispose that
   lands while the `function_call_output` send is in flight makes the operation
   inert: no `response.create`, no failure, and a late send success OR error is
   swallowed (no unhandled Zone error). The normal flow still sends exactly one
   output then exactly one create.
2. **Guardrail replacement ownership across the gated cancel/clear.** The
   fail-closed / replacement operation is bound to the original assistant
   turn/epoch and re-checked after the awaited `response.cancel` /
   `output_audio_buffer.clear` and immediately BEFORE the replacement
   `response.create`. A new valid `speech_started` during that gate leaves the
   session in `userSpeaking` and creates no replacement; a stop/dispose during the
   gate creates no replacement and raises no late failure or unhandled error; a
   normal (ungated) block still creates exactly one replacement response.

### Corrective P1 fixes — round 2

Four further audit findings fixed (no scope change):

1. **Full `function_call` count.** A completed `response.done` is scanned for ALL
   `function_call` items: two or more is a protocol violation (`parallel_tool_calls:
   false`) that terminates the session (`transport`) — resolver, output and create
   are never sent. A single structurally-valid call with invalid `arguments` stays
   a safe error `ToolResult`.
2. **No pending-resolver race between turns.** Each pending tool operation is
   correlated with its own identity token; a stale/interrupted operation clears
   only itself and can never touch a newer operation's pending state.
   `interruptResponse()` invalidates exactly the current pending operation.
3. **The assistant final transcript is never published `interrupted: false`
   prematurely.** It is held until the reply's outcome is decided — published
   `interrupted: false` only after a valid final transcript AND
   `response.done(completed)` AND `output_audio_buffer.stopped` AND (guardrail) an
   allow verdict AND no interruption; otherwise `interrupted: true`. Never published
   `false` then corrected; still exactly-once; works with the guardrail on or off;
   the exact-final guardrail callback still fires immediately (only the public
   publication is delayed).
4. **Strict VAD-pair validation.** One package-private VAD state (identical with
   recording ON or OFF) validates a start (non-empty `item_id`, non-negative
   `audio_start_ms`, no open segment, not-yet-used `item_id`) and a stop (matching
   `item_id`, non-negative `audio_end_ms >= audio_start_ms`) BEFORE any turnId /
   epoch / phase / mic / recording / budget change. Malformed, duplicate,
   overlapping, reused and foreign VAD events are fully inert.

### Corrective P1 fixes — round 1

Seven audit findings fixed within the same increment (no scope change):

1. **Runtime tool-argument validation.** Tool `arguments` are now validated
   against the tool's Chat AI Tool Schema v1 declaration (a self-contained
   instance validator, no new dependency); the resolver runs only for a JSON
   object that conforms. Unknown tool / malformed / non-object / schema-mismatch /
   resolver exception → sanitized `ToolResult(isError: true)`; nothing sensitive
   reaches the wire, state, events or logs.
2. **Duplicate `call_id`** is now a terminal `transport` protocol failure (one
   teardown, never re-run or re-sent), instead of a silent no-op.
3. **`interruptResponse()` during a pending tool resolver** now cancels the tool
   chain (invalidating the late resolver result) WITHOUT a meaningless
   `response.cancel`; `conversation` returns to `listening`, `singleTurn` ends.
4. **A malformed function call** (missing/empty `call_id` or `name`) terminates
   immediately as `transport` instead of being mistaken for an audio completion
   (no resolver, no output/create, no timeout wait, one teardown).
5. **The one-replacement guardrail budget is now per USER TURN** (reset on each
   new valid user speech turn), not session-global.
6. **The mandatory final guardrail check now uses the AUTHORITATIVE exact final
   transcript** (`response.output_audio_transcript.done`), works even when
   `transcriptsEnabled == false`, and the public final transcript is no longer
   published as `interrupted: false` before an allow verdict (a block/exception
   publishes it `interrupted: true`). If audio completes before the final
   transcript, the wait is bounded by the existing idle watchdog (a lost final
   transcript → controlled `responseTimeout`). The replacement runs the same
   exact-final flow.
7. **At most one app guardrail callback runs at a time across the whole session:**
   a turn change makes an in-flight callback logically stale but not physically
   finished; a new turn's check waits until the old callback truly resolves, and
   a late stale result creates no replacement.

(An eighth finding — stricter VAD-pair validation — was deferred in round 1 for
scope reasons and is now implemented in round 2 above, with the item_id-less /
start-less VAD test fixtures normalized to full valid pairs.)

### Added

- **Initial history.** New `initialConversation` constructor parameter (a core
  `Conversation`). It is validated synchronously before any mint (only
  `schemaVersion == 1`; a `sending` user or a `streaming` assistant throws
  `ArgumentError`) and seeded as `conversation.item.create` items **before the
  microphone goes live**. It maps system text, user text, user JPEG images,
  assistant text and **completed** `ToolCall`+`ToolResult` pairs; it filters out
  `failed` users, `ProviderOpaquePart`, incomplete tool calls, orphan tool
  results, empty assistants and all local `Message.id` / statuses / timestamps /
  attempt keys (an `interrupted` assistant is preserved). Items go out one at a
  time: the next one waits for a well-formed `conversation.item.added` (a
  malformed ack confirms nothing) within `responseIdleTimeout`; the mic arms only
  after the whole history is acknowledged. A server error, a transport death or a
  lost acknowledgement during loading is a terminal `session` failure with no
  retry. The passed object is never mutated, normalized, shortened or stored.
  `session.update` now sets `"truncation": "disabled"`.
- **Universal tools.** New `onToolCall` and `maxToolTurns` (default 5)
  constructor parameters, reusing the core `Tool` / `ToolCall` / `ToolResult` /
  `OnToolCall`. Configuration is validated synchronously (positive
  `maxToolTurns`; non-empty tools require `onToolCall`; names / duplicates / JSON
  Schema per the Chat AI Tool Schema v1 dialect). `session.update` carries the
  tools, `tool_choice: "auto"` and `parallel_tool_calls: false`. One tool call at
  a time from a completed `response.done`; unknown tool / invalid arguments /
  resolver exception become a sanitized `ToolResult(isError: true)` (no exception
  text or stack trace on the wire or in logs); a duplicate `call_id` is never
  re-executed; a successful result is one `function_call_output` followed by
  exactly one `response.create`, with no retry after either send. A per-reply cap
  ends a runaway loop with the new coarse failure `toolLoopLimit`.
- **Output guardrail.** Optional, default-off, low-latency **post-generation**
  guardrail via new `outputGuardrail` and `safeReplacementInstructions`
  constructor parameters, plus the new public `OpenAIRealtimeVoiceGuardrailDecision`,
  `OpenAIRealtimeVoiceOutputGuardrail` and `OpenAIRealtimeVoiceGuardrailEvent`
  (turnId only), and a `guardrailEvents` stream. It accumulates the exact
  assistant transcript, checks at most once per fixed 250 ms with a single
  callback at a time (coalescing new text), always runs a mandatory final check
  the reply's completion waits for, and works even when `transcriptsEnabled` is
  `false` without enabling input ASR. The first block or callback exception fails
  closed: cancel → clear → interrupted recording → one coarse event → exactly one
  no-context / no-tools replacement with a new assistant `turnId`. A block inside
  the one allowed replacement is terminal (`guardrail` failure); no second
  replacement is ever created.
- **Local `turnId`s.** Every reply now carries a local UUID v4 `turnId` (never an
  OpenAI id) linking its delta, final transcript, recording and recording
  failure. `OpenAIRealtimeVoiceTranscript` gained `turnId` + `interrupted`;
  `OpenAIRealtimeVoiceRecording` and `OpenAIRealtimeVoiceRecordingFailure` gained
  `turnId`; the new `OpenAIRealtimeVoiceTranscriptDelta` carries `turnId` + the
  raw `delta`. A late final transcript of an interrupted assistant turn is
  delivered with `interrupted: true`. A recording failure is never anonymous — a
  side whose native tap fails to attach before any reply surfaces its one failure
  only when a concrete reply begins, tied to that reply's `turnId`. All new
  models' `toString()` stay privacy-safe (no transcript / delta / path /
  instructions / provider ids).

### Changed / breaking

- `assistantTranscriptDeltas` is now
  `Stream<OpenAIRealtimeVoiceTranscriptDelta>` (was `Stream<String>`); the raw
  fragment moves to `delta.delta` and each event now carries `delta.turnId`. The
  old `Stream<String>` is gone.
- The public surface grew from ten to **fourteen** declarations (the typed
  transcript delta plus the three guardrail declarations).
- A non-empty `botProfile.tools` is now **supported** (with `onToolCall`) instead
  of throwing.

### Dependencies

- Added a direct dependency on `uuid` (`^4.5.3`) for the local `turnId`s.

### Not included / limits

- No reconnect / retry / re-mint, no persistence / database / history inside the
  package, no on-device classifier, no UI, no Android recording.
- `maxToolTurns = 5` and the guardrail's 250 ms interval are limits of this
  package, not of the OpenAI Realtime API.
- The physical iPhone smoke has **not** been re-run for this increment.
