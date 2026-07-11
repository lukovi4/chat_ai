---
status: accepted
---

# Bot Profile is the minimal agent triad: id + system prompt + tools

A Bot Profile carries exactly **three fields**: `id` (the tier *request* the
server resolves to a model, ADR 0001), `systemPrompt` (the persona, rides in
the assembled context, ADR 0002), and `tools` (the Tool declarations,
ADR 0003). Nothing else — in particular, **no generation parameters**.

This is the industry core of an agent config: OpenAI's Agents SDK builds an
Agent from name + instructions + model + tools; Anthropic's Managed Agents
require name + model with system + tools alongside. Our triad is the same
minus what our architecture already moved server-side (the model, behind the
tier→model map) or made the app's own concern (naming its profiles in code).

## Considered Options

- **Include generation parameters** (temperature, top_p, max tokens…).
  Rejected: the newest provider models **reject sampling parameters outright**
  (Anthropic Opus 4.7+/Sonnet 5 return 400 on `temperature`/`top_p`; prompting
  is the steering mechanism), and OpenAI relegates them to an optional
  `model_settings` extension. Where a model genuinely needs a knob (e.g. a
  max-tokens value), the knob is a **property of the model** — it lives next
  to the model in the server's tier→model config, changing with it, without an
  app release. A profile knob would leak model-specific detail into every app.
- **A direct model id in the profile.** Rejected by ADR 0001: the client sends
  an intent; the server resolves the actual model, so models and pricing rules
  change with no app release, and entitlement is re-checked where the key lives.
- **Name/description metadata.** Rejected: the providers' `name` is console
  display metadata; here the app declares its own profiles in its own code —
  naming is the app's concern, not the Package's.

## Consequences

- The profile is a small, stable, serializable value; the public API and the
  wire request stay minimal.
- Switching bots mid-conversation is free by construction (stateless — the
  profile rides on every send); see CONTEXT.md §Bot Profile.
- Extensions (skills, structured output, per-profile params if a future model
  family re-introduces them) can be added **additively** without breaking the
  triad — the same growth path the providers' own agent configs use.
- Nothing model-specific ships in the app: adding/renaming/re-tuning models is
  a server-config change only.
