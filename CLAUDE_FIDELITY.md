# CLAUDE_FIDELITY — the agent, measured against Claude Code

Scope: `agent/Agent.lua`, `agent/Tools.lua`, `agent/providers/Anthropic.lua`,
and the console's replay path where it decides what the model or the reader
sees. The shell has its own audit in `BASH_FIDELITY.md`.

Claude Code is the quality baseline, so this is the audit of how far we are from
it and which gaps cost the agent something. Same rule as the bash file: **keep
this honest or delete it.** The point of the file is §4; everything else is
context for it.

Source read from the v2.1.88 sourcemap leak. Re-verify with:

```
curl -sL https://raw.githubusercontent.com/davccavalcante/claude-code-leaked/main/src/<path>
```

Every line reference below was read at the commit `main` pointed to on
2026-09-03. Claims are marked **[verified]** when I read the file this pass and
**[unverified]** when they come from an in-code comment I did not re-check —
treat the second kind as a lead, not a fact.

---

## 1. The shape

Claude Code, per `src/query.ts`:

```
turn → snipCompact          (:396  collapse, before everything)
     → microcompact         (:412  clear old tool results by tool_use_id)
     → autocompact          (:453  summarise spans of history into a paragraph)
     → request
     → checkTokenBudget     (continue the turn, or stop)
```

Ours, per `agent/Agent.lua`:

```
turn → capTurn/forModel     (:144,:183  cap this turn's results)
     → clearOldToolResults  (clear old tool results, cold-cache only)
     → request
     → budgetContinuation   (continue the turn, or stop)  [ported]
```

The budget stage matches: armed per message by `+500k` or `use 2m tokens` in the
prompt (`parseTokenBudget`), inert otherwise, both thresholds upstream's.

Two of their four context stages exist here, and the missing one — summarising
compaction — is the headline, expanded in §4.1.

---

## 2. What is genuinely faithful

Worth stating first, because the request path is in better shape than the UI is.

| Area | Detail | Status |
|---|---|---|
| Thinking continuity | `Agent.lua:995-1014` replays thinking blocks verbatim with their `signature`, never reordered or partly dropped, because the model pauses mid-response to call a tool and resumes the same response. Under `display: "summarized"` the text is a summary and the signature is what the server decrypts. | [verified] |
| `redacted_thinking` | Matched explicitly (`:1010`) rather than by `type == "thinking"`, so safety-redacted reasoning is not silently dropped and the block run still pairs. | [verified] |
| Citations | Preserved on text blocks (`:1019`). | [verified] |
| Microcompact constants | `KEEP_RECENT = 5` and `COLD_AFTER = 60 * 60` are **exactly** their `keepRecent: 5` and `gapThresholdMinutes: 60` (`timeBasedMCConfig.ts:32-33`). Not a coincidence — it was ported deliberately. | [verified] |
| Time-based trigger | Their `evaluateTimeBasedTrigger` (`microCompact.ts:422`) is the one free microcompact path a plugin can have: the TTL we asked for is knowable client-side. Their other two are not — `cache_edits` needs the server-side context-management API, autocompact needs somewhere to spill. `Agent.lua:392-398` states this and it is correct. | [verified] |
| Cleared-result stub | Never remove the block, only blank the content — a dropped `tool_result` orphans its `tool_use` and every later request fails. Their sentinel is `'[Old tool result content cleared]'` (`microCompact.ts:36`); ours is longer on purpose, because they persist cleared output and can restore it, and we cannot. `Agent.lua:366-369` quotes their string correctly. | [verified] |
| Truncation honesty | `forModel` names the narrower commands to re-run rather than just cutting. `find`/`grep` keep walking past `MAX_RESULTS` purely so "… N more matches" is a real count. `seq` refuses at its cap instead of returning half a sequence. | [verified] |
| Truncated tool JSON | A tool input cut off by `max_tokens` arrives as invalid JSON; `Agent.lua:1116-1126` reports the `stop_reason` and tells the model to retry smaller, rather than dropping the call. | [verified] |

---

## 3. Deliberately not ported

Not gaps. Recording them so they are not "fixed" into existence later.

- **Spill-to-disk for cleared tool output.** Claude Code persists what
  microcompact clears and can restore it after a compaction. A plugin has
  nowhere to spill, which is exactly why our stub names the recovery ("re-run
  the command") instead of saying nothing.
- **Virtualized transcript.** Their `useVirtualScroll.ts` mounts only viewport +
  `OVERSCAN_ROWS = 80` and holds the rest open with spacer boxes, so
  `jumpToIndex` is a `scrollTo` (`VirtualMessageList.tsx:698`) and a jump
  contends with nothing. Ours redraws a bounded window. Porting it needs a
  per-block height cache invalidated on width change — they hit that trap and
  left the note ("cached heights from a different width are wrong → black
  screen on scroll-up after widen"). Tracked as a `ponytail:` on
  `Sessions.lua`'s `windowEnd`.
- **`count_tokens` for the context breakdown.** They call
  `POST /v1/messages/count_tokens` once per category, in parallel, with a Haiku
  fallback (`analyzeContext.ts`) — a round trip per row of `/context`.
  `Agent.contextBreakdown` scales a local character count to the exact total the
  last reply billed, so a uniform error in the bytes-per-token constants cancels
  and the rows are right relative to each other for zero requests. Do not
  "upgrade" this into six HTTP calls per settings open.
- **Separate read vs shell result budgets.** They split shell output from file
  reads because a read is a primary operation and shell output is incidental.
  We take one number for both, because `cat` is not a separate tool here — it
  arrives as a `bash` line, and `cat x | grep y` has no honest classification.
  Reasoned out at `Agent.lua:95-108`. **[unverified]** — their two constants
  were not re-read this pass.

---

## 4. Divergences that cost the agent something

Ranked by what they cost, not by effort to close.

### 4.1 No summarising compaction — a long session dies with no way back

`clearOldToolResults` only blanks `tool_result` content. A session that grows on
**assistant text and the reader's own messages** has nothing for it to clear, so
`conversation` is append-only until it hits the context window and the session is
over.

Claude Code has three layers we have one of: `snipCompact` (collapse),
`microcompact` (what we have), and `autocompact` (`query.ts:453`), which replaces
spans of history with a paragraph. Only the third is a real answer to
non-clearable growth.

This is already marked `ponytail:` at `Agent.lua:381-385`, and `culprits.md`
measured the shape of it independently: the crash-mirror ladder pins at its floor
once non-clearable content alone exceeds 150 KB, which is the same growth seen
from the other end.

**Cost:** the session ends. Nothing degrades first — it works, then it stops.

### 4.2 Compaction has no tool allowlist

`microCompact.ts:41` clears results only for tools on `COMPACTABLE_TOOLS`
(read, shell, grep, glob, web search, web fetch, edit, write) — an **allowlist**,
so a tool whose result cannot be reproduced by re-running is never cleared.

`clearOldToolResults` has no such concept and clears every tool's results. Of our
six, `run` is the one that matters: re-running code is not guaranteed to
reproduce the result, because the run had side effects on the DataModel. The stub
tells the model to re-run, and for `run` that advice can be wrong.

**Cost:** low frequency, silent when it happens. Fix is a set literal and one
condition.

### 4.3 No max-output-tokens recovery loop

`query.ts:164` carries `MAX_OUTPUT_TOKENS_RECOVERY_LIMIT = 3`. We detect the
truncated-JSON case and report it to the model (§2), but there is no bounded
automatic retry.

**Cost:** one wasted turn per occurrence, and the model is told what happened, so
it can recover on its own. Lowest item here.

---

## 5. Not a divergence, checked and cleared

Kept so they are not re-investigated.

| Suspicion | Killed by |
|---|---|
| `_unparsed` / `_restored` fabricate a tool argument the model never sent | All six tools carry a `required` array, so an empty `input` is never legitimate. Both only fire on an already-malformed call, where the alternative is a session the API rejects on every later request. |
| Tool results truncated without telling the model | `forModel` appends the character count and names `head -n`, `tail -n`, `sed -n`, `grep` as the way to see the rest. |
| `find`/`grep` caps hide how much was missed | The walk continues past the cap purely to count, so "… N more matches" is a number. |
| Thinking dropped or reordered across a tool call | Verified verbatim replay with signatures, §2. |
| Crash-mirror stubbing degrades what the model sees | `stubOldResults` returns a copy; `Sessions.selfTest` asserts it never mutates the live conversation. It is the disk copy only. |

---

## 6. Endpoints

What Claude Code calls that we do not. [verified] against the leak on
2026-09-03. Nothing here is wired up; each is its own decision.

**Not a gap — a stale host.** We post to `console.anthropic.com/v1/oauth/token`
and authorize at `claude.ai/oauth/authorize`. Current Claude Code uses
`platform.claude.com/v1/oauth/token` and `claude.com/cai/oauth/authorize`
(`constants/oauth.ts:89,91`), with a matching
`platform.claude.com/oauth/code/callback` redirect. Console **307s today**, so
login works; we are depending on a redirect that is nobody's contract. This is
the one item here worth acting on, and it is an auth change, not a feature.

Applicable to a plugin — has an OAuth token, no filesystem, no MCP, no subagents:

| Endpoint | Would buy |
|---|---|
| `POST /v1/messages/count_tokens` | An exact pre-send token count; we have none. Does **not** contradict §3, which is about the context *breakdown* — that total is already exact and free. |
| `GET /api/claude_cli_profile` (fallback `/api/oauth/profile`) | Account + org identity, and the `x-organization-uuid` several other endpoints want. |
| `GET /api/oauth/claude_cli/roles` | Org membership and role. |
| `GET /api/claude_cli/bootstrap` | One startup call: entitlements and notices. |
| `POST /api/oauth/claude_cli/create_api_key` | Mints a durable API key from an OAuth session — would remove refresh-token rotation from Studio entirely. Note [[anthropic-device-flow-unauthorized]]. |
| `GET`/`PUT /api/oauth/account/settings` | Settings that survive a plugin reinstall. |
| `POST /api/claude_cli_feedback` | Feedback with no browser trip. |

**Not gaps, recorded so they are not rediscovered:** Claude Code calls neither
`GET /v1/models` (its roster is config-driven — so the note at `Anthropic.lua:86`
proposing it is a divergence *from* upstream, not toward it) nor the Batches API.

**Inapplicable:** bridge/environment, CCR worker, session teleport, MCP, files,
ultrareview quota, Bedrock/Vertex/Azure clients, update channels. And all
telemetry — `event_logging/batch`, `claude_code/metrics`, Datadog, OTLP,
GrowthBook — which would be a new privacy commitment, not a feature.

---

## 7. To close the last gaps

In the order I would take them:

1. **Recalibrate `clearOldToolResults` off the model's context window.**
   `TRIGGER_CHARS = 200000` and `URGENT_CHARS = 600000` are fixed, while
   `MODEL_CAPS` knows `claude-opus-5` and `claude-sonnet-5` carry
   `context = 1000000` and only `haiku-4-5` carries `200000`. So on the two
   models actually in use, tool results are permanently destroyed — no
   spill-to-disk, gone — at **15% of the window**, where the same number is a
   correct 75% on Haiku. One constant, right for the model it was tuned against
   and wrong for the rest. `contextWindow(model)` is already exported by both
   providers (`Anthropic.lua:836`, `OpenRouter.lua:857`) and used only by the
   settings panel, so the plumbing is there. Not in §4 because it is not a
   divergence from Claude Code — theirs is calibrated the same way — but it is
   the highest-value item on the page.
2. **§4.2, allowlist.** A set and a condition.
3. **§4.1, summarising compaction.** The big one, and the only one that needs a
   design: what to summarise, with which model, and how to mark the boundary so
   a restored session does not re-summarise its own summary.
4. **§4.3, recovery loop.** Only if it turns up in practice.
