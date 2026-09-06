# CODEX_FIDELITY — the OpenAI provider measured against Codex

Scope: `agent/providers/OpenAI.lua`, `agent/providers/OpenAIAuth.lua`, the
provider-neutral turn loop in `agent/Agent.lua`, and the session/replay path that
must retain OpenAI ResponseItems across tool calls and restarts.

This is a protocol audit, not a claim that a Roblox Studio plugin is the Codex
CLI. The useful standard is narrower: when the OpenAI provider authenticates,
sends a turn, executes a tool, follows up, restores a session, reports cached
tokens, or reaches a subscription limit, it should make the same protocol
decisions as first-party Codex unless this file names the difference.

**Keep this honest or delete it.** A working first answer is not fidelity. Tool
loops, encrypted reasoning continuity, cache identity, refresh-token rotation,
and restored sessions are the parts that reveal whether the implementation is
actually compatible.

## Source and status language

Upstream was read at OpenAI `openai/codex` commit
[`8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9`](https://github.com/openai/codex/tree/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9),
committed 2026-09-06 21:07 UTC. The protocol-critical sources are:

- [`device_code_auth.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/login/src/device_code_auth.rs)
- [`auth/manager.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/login/src/auth/manager.rs)
- [`bearer_auth_provider.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/model-provider/src/bearer_auth_provider.rs)
- [`codex-api/common.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/codex-api/src/common.rs)
- [`codex-api/sse/responses.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/codex-api/src/sse/responses.rs)
- [`core/client.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/core/src/client.rs)
- [`core/session/turn.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/core/src/session/turn.rs)
- [`core/stream_events_utils.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/core/src/stream_events_utils.rs)
- [`codex-api/rate_limits.rs`](https://github.com/openai/codex/blob/8d7cc24a87f4aa66aa434eb4f25f4f4bafc0e0a9/codex-rs/codex-api/src/rate_limits.rs)

OpenAI's public [Responses API reference](https://developers.openai.com/api/reference/resources/responses/methods/create)
is useful for the item schema. The ChatGPT subscription route itself is an
internal Codex contract, so the upstream client is authoritative for that part.

Statuses used below:

- **[exact]** — same wire value or turn decision as the pinned upstream source.
- **[adapted]** — same protocol outcome through a Roblox-compatible mechanism.
- **[gap]** — upstream behavior is applicable but absent or materially weaker.
- **[out of scope]** — part of the Codex product, not required for this provider.

## 1. Bottom line

The provider is faithful at the four boundaries that decide whether subscription
Codex works at all:

1. It uses ChatGPT OAuth and the account-backed Codex route, never the separately
   billed Platform API. **[exact]**
2. It sends the Responses request shape Codex expects with `store=false`, then
   keeps encrypted reasoning and exact function-call items for stateless replay.
   **[adapted]**
3. A function call and `response.completed.response.end_turn == false` both cause
   another sampling request. **[exact]**
4. Subscription windows and credits come from `codex.rate_limits` events and
   `x-codex-*` headers, not from an invented token-price meter. **[exact]**

It is not yet transport- or cache-identical. Upstream supplies a stable
`prompt_cache_key`, can reuse a turn-scoped WebSocket with sticky routing, and
refreshes model metadata dynamically. We do none of those. Local calls are also
executed sequentially even though the request permits parallel calls. Those are
the meaningful remaining gaps; they are ranked in §11.

## 2. Hard billing boundary

This is an invariant, not a preference:

> The OpenAI provider consumes the signed-in user's ChatGPT Codex subscription
> limits. It must never accept an API key, call `api.openai.com`, or silently
> fall back to separately billed Platform usage.

Enforcement in the implementation:

- `OpenAI.RESPONSES_URL` is pinned to
  `https://chatgpt.com/backend-api/codex/responses`.
- `OpenAIAuth` exposes no API-key login path.
- A pasted value beginning with `sk-` is rejected.
- The legacy `openai_api_key` plugin setting is cleared on initialization,
  successful token writes, and logout.
- `OpenAI.selfTest` rejects a responses URL containing `api.openai.com`.

This intentionally differs from the full Codex CLI, which also supports API-key
and custom-provider modes. Those modes are **[out of scope]** here because adding
them would violate the product requirement rather than increase fidelity.

## 3. Endpoint inventory

These are all OpenAI endpoints the provider currently uses:

| Method | Endpoint | Purpose | Status |
|---|---|---|---|
| `POST` | `https://auth.openai.com/api/accounts/deviceauth/usercode` | Start device authorization and receive `device_auth_id`, user code, and polling interval. | **[exact]** |
| browser | `https://auth.openai.com/codex/device` | Reader signs into ChatGPT and approves the displayed code. | **[exact]** |
| `POST` | `https://auth.openai.com/api/accounts/deviceauth/token` | Poll until the authorization code and server-created PKCE verifier are ready. | **[exact]** |
| `POST` | `https://auth.openai.com/oauth/token` | Exchange the authorization code; later rotate access/refresh tokens. | **[exact]** |
| `POST` | `https://chatgpt.com/backend-api/codex/responses` | Stream model output against the user's Codex subscription. | **[exact]** |

There is no usage endpoint. Quota snapshots arrive with response traffic. There
is also no `/v1/models` call today; that omission is a real roster-freshness gap,
covered in §9 and §11.

## 4. Authentication fidelity

### What matches

`OpenAIAuth.lua` uses Codex's client id
`app_EMoamEEZ73f0CkXaXp7hrann`, its device-auth paths, 15-minute authorization
timeout, and `/deviceauth/callback` token-exchange redirect. The browser never
has to call Roblox: after approval, the plugin polls the authorization service
and receives the authorization code and verifier itself. **[exact]**

The returned ID token supplies:

- `chatgpt_account_id`, sent as `ChatGPT-Account-ID`;
- `chatgpt_plan_type`, used only as a quota label;
- `chatgpt_account_is_fedramp`, which adds `X-OpenAI-Fedramp: true`.

Requests also send `Authorization: Bearer <ChatGPT access token>`. Those three
headers match upstream `BearerAuthProvider`. **[exact]**

Tokens refresh before access-token expiry and once after a 401. Refresh-token
rotation is persisted, and an ID token that changes the account during refresh
is rejected. That preserves the same-account invariant across a live session.
**[adapted]**

### Roblox adaptations

- Codex can run a localhost browser callback; Studio cannot host the equivalent
  callback reliably, so this provider is device-flow only. **[adapted]**
- The reader pastes the same one-time code back into the plugin to begin polling.
  It is a local confirmation, not a secret returned by the website and not a
  second OAuth credential. **[adapted]**
- Upstream can persist credentials in `auth.json` or an OS keyring. Roblox plugin
  settings are the only durable store available here. They are less protected
  than an OS credential vault. **[gap]**
- Upstream classifies refresh failures such as expired, reused, and revoked
  refresh tokens separately and caches permanent failures. Ours returns the
  service error and asks for login again, but does not preserve that taxonomy or
  failure cache. **[gap, low impact]**

## 5. Request contract

One request is built in `OpenAI.streamMessage`; `Stream.open` owns transport and
retry. The stable body is:

| Field | Ours | Upstream | Assessment |
|---|---|---|---|
| `model` | selected model id | model metadata slug | **[exact]** |
| `instructions` | shared system prompt, omitted when empty | base instructions, serialized empty-safe | **[exact]** |
| `input` | full translated conversation | formatted rollout ResponseItems | **[adapted]** |
| `tools` | local function schemas plus optional `web_search` | generated tool registry | **[adapted]** |
| `tool_choice` | `auto` when tools exist | `auto` | **[exact]** |
| `parallel_tool_calls` | `true` | normally true when the model supports it | wire **[exact]**, execution **[gap]** |
| `reasoning` | selected effort, `summary="auto"` | model/config-derived effort and summary | **[adapted]** |
| `store` | `false` | `false` | **[exact]** |
| `stream` | `true` | `true` | **[exact]** |
| `include` | `reasoning.encrypted_content`; web sources when enabled | `reasoning.encrypted_content` | **[exact]** plus UI data |
| `prompt_cache_key` | absent | session id, or an internal parent-thread namespace | **[gap]** |
| `stream_options` | absent | optional sequential-cutoff reasoning-summary delivery | **[gap, optional]** |
| `service_tier` | absent | model/config-derived when applicable | **[out of scope]** |
| `text` | absent | optional verbosity/output-schema controls | **[out of scope]** |
| `client_metadata` | absent | session/turn and tracing metadata | **[gap, low direct impact]** |
| `access_programs` | absent | conditionally attached for specialized access | **[out of scope]** |

`max_tool_calls` is deliberately absent. The ChatGPT Codex endpoint rejected it
with `400 Unsupported parameter`; web-search count remains an enable switch for
OpenAI while providers that support a hard maximum keep their own limits. The
removed `stream_options.include_obfuscation` field was likewise not part of the
current Codex request schema.

Upstream also sends originator/session/turn metadata headers used for routing,
diagnostics, and product behavior. Our protocol-critical auth headers are exact,
but those contextual headers are not sent. **[gap]**

## 6. ResponseItems, reasoning, and history

The plugin's shared history looks Anthropic-like, but OpenAI wire state is not
flattened into plain chat text.

### Reasoning

The request asks for encrypted reasoning and an automatic summary. OpenAI does
not expose the model's private chain of thought; one-line `summary_text` events
are normal. `OpenAI.lua` forwards every reasoning-summary delta to the thinking
drawer and retains `reasoning.encrypted_content` for the next request. The UI
does not reduce a multi-line summary to one line. **[exact]**

The first reasoning block's opaque signature contains the complete original
output sequence and the source model. This lets a stateless request replay the
reasoning item and its paired output items byte-for-structure rather than
reconstructing an orphan. If the model changes, model-bound encrypted reasoning
is discarded while visible text/function items are rebuilt safely. **[adapted]**

The summary mode is fixed to `auto`; upstream can derive/configure other summary
modes and sequential-cutoff delivery. Richer selectable summaries are a UI/config
gap, not access to hidden reasoning. **[gap, low impact]**

### Function calls

Mapping is one-to-one:

```
Responses function_call.call_id
    -> internal tool_use.id
    -> local tool_result.tool_use_id
    -> Responses function_call_output.call_id
```

Arguments are retained as their streamed JSON string and parsed for dispatch.
`response.function_call_arguments.done` is treated as the authoritative complete
JSON when deltas were coalesced. The exact function-call ResponseItem is also
stored as opaque `providerState`, so a function-only response still preserves
its server id and status when no reasoning envelope exists. **[adapted]**

The completed response and incremental `output_item` events are merged by
`output_index`. This matters because a relay can stream a complete function call
but leave `response.completed.output` empty or incomplete; trusting only the
final envelope made the tool visible live, then erased it from history. **[adapted]**

### Hosted web search

`web_search_call` becomes a display call plus a paired internal result carrying
the exact OpenAI item. The local agent never dispatches it because the service
already ran it. Sources are requested for display. **[adapted]**

Other current Codex ResponseItem variants—custom tools, local-shell calls, tool
search, image generation, compaction triggers, and configuration updates—are not
parsed by this provider. The plugin does not advertise those tools, so they are
normally **[out of scope]**; if the server begins emitting one without it being
requested, it will currently be ignored rather than surfaced. **[gap, defensive]**

## 7. Turn-loop fidelity

Upstream sets `needs_follow_up` in two independent cases:

1. a tool-call ResponseItem was completed;
2. `response.completed` carries `end_turn: false`.

The plugin now matches both. Local function calls are executed, every call gets
a non-empty `function_call_output`, all outputs from the batch are appended, and
another request is scheduled. A Codex bridge response with `end_turn=false` also
schedules another request without inventing an assistant message. **[exact]**

This last detail fixes two formerly coupled failures: the model stopped after a
tool result, and restored OpenAI sessions showed the synthetic text `"(empty)"`
where the continuation bridge had been. New OpenAI bridge responses are omitted
from history exactly as no-output upstream events are. Already-corrupted saved
entries cannot be reconstructed.

Important differences:

- Upstream starts tool futures as calls complete and can have several in flight.
  We advertise `parallel_tool_calls=true` but execute the returned array with a
  sequential Lua loop, then send one output batch. Semantics are preserved;
  latency and cancellation behavior are not. **[gap]**
- Upstream treats a stream ending before `response.completed` as an error. The
  shared Roblox stream layer salvages text/items on a clean early close so the UI
  cannot spin forever. That can convert a truncated function call into a parse
  error returned to the model instead of retrying the whole response. **[gap,
  deliberate resilience tradeoff]**
- Upstream can accept pending user/mailbox input during a running turn. The
  plugin exposes Stop and starts new typed input after the active turn. **[out of
  scope]**

## 8. Streaming and retry

Roblox `RawStream` is framed as SSE manually across LF, CRLF, and CR blank-line
separators. JSON error responses are recognized before SSE parsing so a 400/401/
429 body is not hidden behind a content-type failure. The provider handles text,
refusal, reasoning-summary, reasoning-content, function-argument, output-item,
completion, incomplete, failure, and Codex quota events. **[adapted]**

Retries are allowed only before any content or tool call reaches the UI; after
emission, replaying a request would duplicate visible and historical items. One
401 can refresh credentials and retry. Rate limits honor server reset headers,
and long subscription windows are reported instead of repeatedly spending
attempts. **[adapted]**

Upstream can use a turn-scoped WebSocket and preserve sticky routing state, with
SSE support beneath the same response model. Roblox exposes the HTTP stream used
here, so this provider is SSE-only. **[gap]**

Several upstream administrative events are not surfaced: model ETag refresh,
server-model mismatch, model verification, reasoning-included headers, safety
buffering, and moderation metadata. None is needed to pair a tool result, but
silently ignoring a future model migration signal is meaningful. **[gap]**

## 9. Models, caching, usage, and subscription limits

### Models

The picker is curated in `OpenAI.MODELS`; `/model <id>` accepts additional
Responses-compatible OpenAI ids by pattern. Upstream has a models manager,
cached metadata, and can react to the `x-models-etag` signal. Static context
windows, supported features, defaults, and display names can therefore drift in
this plugin. **[gap]**

Do not replace the picker with an unfiltered public model list. Availability
alone does not establish Responses, Codex entitlement, tool, reasoning, or web
search compatibility. The faithful solution is the Codex model-metadata route
and its cache/ETag behavior, not `GET /v1/models` dumped into a menu.

### Prompt caching

The provider sends the full conversation on each stateless request, preserves
stable prefixes, and reports `cached_tokens` from actual response usage. Agent
avoids clearing old tool results while a prefix is warm unless the context is
near its urgent line. Cache hits are therefore real, not estimated. **[adapted]**

But upstream always computes `prompt_cache_key`—normally the session id—and puts
it in `ResponsesApiRequest`. We omit it and also omit the upstream session/turn
routing metadata. Automatic prefix matching may still hit, but cache identity
and routing are weaker than Codex's. This is the highest-value protocol gap.
**[gap]**

Usage is rebased into fresh input, cache read, cache creation when present, and
output counts so the common session panel remains provider-neutral. This is
accounting display, not a bill. **[adapted]**

### Subscription limits

`OpenAIAuth` reads both forms upstream understands:

- `codex.rate_limits` SSE snapshots;
- default `x-codex-primary-*`, `x-codex-secondary-*`, and
  `x-codex-credits-*` headers.

It displays the plan, rolling-window utilization/reset time, and credit state.
There is no dollars-per-token calculation and no Platform quota lookup.
**[exact]**

Current upstream can parse multiple named rate-limit families announced by a
limit-id header. Ours retains only the default primary/secondary family, so a
future account with several independent Codex limits may see an incomplete
usage panel. **[gap]**

## 10. Session persistence

Sessions are provider-bound because encrypted reasoning and item metadata are
not portable. Loading an OpenAI session while another provider is active is
refused rather than flattened or silently corrupted. **[exact outcome]**

The complete active conversation is JSON-encoded into chunked values under
`ServerStorage/AgentSessions`. A bounded plugin-setting mirror protects against
an unsaved place/crash; old tool outputs may be stubbed only in that mirror. Cold
sessions are compressed. None of those storage mechanics changes what the live
request sees. **[adapted]**

OpenAI-specific persistence retains:

- encrypted reasoning plus the response output sequence;
- exact function-call items through `providerState`;
- parsed tool input for UI replay;
- every `tool_use.id` / `tool_result.tool_use_id` pair;
- exact hosted-tool items.

`OpenAI.selfTest` JSON-round-trips a function-only call and its output, then
rebuilds the two correct Responses items. **[verified locally]**

Compared with Codex's rollout/thread store, this plugin has no fork, cloud sync,
cross-machine resume, response-id continuation, or upstream event log. Those are
product features rather than requirements for a correct provider. **[out of
scope]**

## 11. Remaining applicable gaps

Ranked by likely cost:

### 11.1 Send a stable `prompt_cache_key` and session identity

Upstream uses the session id unless an internal parent-thread namespace applies.
Ours sends neither the key nor equivalent session metadata. Add a provider-
neutral stable id to Agent/Sessions, pass it into `streamMessage`, and set
`prompt_cache_key` for OpenAI without perturbing existing message prefixes.

**Cost today:** lower cache affinity, weaker sticky routing, and potentially more
subscription capacity consumed reprocessing the same prefix.

### 11.2 Use Codex model metadata and ETag refresh

The static roster will age. Implement the applicable model-metadata request,
cache it in plugin settings with an ETag, validate capabilities before showing a
model, and keep the curated list as an offline fallback.

**Cost today:** stale availability/context/features, with failures appearing only
after selection.

### 11.3 Make `parallel_tool_calls` honest

Either execute independent tool calls concurrently with deterministic result
ordering, or send `parallel_tool_calls=false`. Concurrency must preserve Stop,
one output per call, history pairing, and DataModel safety; not every editing
tool is safe to overlap.

**Cost today:** multi-read/catalog sweeps take the sum of call latency instead of
the maximum.

### 11.4 Decide strict early-close semantics

Codex errors when the stream ends before completion; the Roblox transport
salvages partial output. Add an OpenAI-specific close policy: a completed
function item may be salvageable, while a partial call should fail rather than
be committed. Keep the current UI guarantee that no spinner survives closure.

**Cost today:** rare incomplete streams can spend an extra model turn repairing a
call that should have been retried.

### 11.5 Parse named quota families and model refresh events

Extend quota storage beyond the default window and handle `x-models-etag` without
making the response parser own the settings UI.

**Cost today:** incomplete quota detail and no automatic roster refresh.

### 11.6 Credential storage hardening

There is no Roblox equivalent to Codex's OS keyring. At minimum, keep tokens out
of logs, never put them in session blobs, clear all values on logout, and document
that plugin settings are the trust boundary. All four are true today; stronger
at-rest protection needs platform support.

## 12. Deliberate non-goals

Do not call these fidelity bugs:

- Platform API keys, `api.openai.com`, per-token billing, or automatic fallback.
- A localhost OAuth callback or external helper process.
- `store=true` and server-stored response continuation.
- Codex telemetry, analytics, feedback, experiments, or update channels.
- MCP servers, subagents, cloud tasks, shell sandboxing, approval policies, and
  Git worktrees belonging to the full Codex runtime.
- Bedrock/Azure/custom OpenAI-compatible providers.
- Showing private chain-of-thought. The supported UI is a reasoning summary.
- Sending unsupported public Responses fields to the private Codex route merely
  because another OpenAI endpoint documents them.

## 13. Regression checklist

`/selftest` should pass every provider, including these OpenAI invariants:

- the subscription URL cannot become `api.openai.com`;
- encrypted reasoning and its paired output survive history;
- function-only calls retain their exact ResponseItem;
- a saved call/output pair survives JSON restore;
- an empty final output cannot discard streamed function calls;
- incomplete final arguments are filled from streamed events;
- `end_turn=false` maps to another sampling turn;
- function call and output keep the same `call_id`;
- request shaping never mutates the live conversation;
- no unsupported `max_tool_calls` or stale stream option is emitted.

Manual release checks, in order:

1. `/logout`, then `/login`; approve the device code and confirm the account/plan.
2. Ask a no-tool question and confirm text, reasoning summary, usage, and save.
3. Ask “what is in the workspace?” and confirm multiple tool calls continue into
   a final answer without the reader typing “continue.”
4. Reload that session; tool names, arguments, outputs, reasoning summaries, and
   final text must still be present—never `"(empty)"` for a bridge response.
5. Continue the restored session and confirm the first request is accepted.
6. Switch providers and verify the OpenAI session is not opened under another
   provider; switch back and verify it restores.
7. Force an expired access token and confirm one refresh/retry, with no API-key
   prompt and no request to `api.openai.com`.
8. Inspect the usage panel after a response carrying quota headers and confirm it
   reports subscription windows, not token prices.

That is the bar: not “it can answer,” but “authentication, wire items, tool
continuation, cache accounting, quota semantics, and restoration all remain
Codex-compatible together.”
