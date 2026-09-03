# FIDELITY — the agent, measured against Claude Code

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
     → clearOldToolResults  (:609  clear old tool results, cold-cache only)
     → request
     → stop                 (the model stopped, so the turn is over)
```

Two of their four context stages exist here, and the loop has no budget
mechanism at all. That is the headline, expanded in §4.1 and §4.2.

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

### 4.2 No token budget, so no continuation and no diminishing-returns stop

`src/query/tokenBudget.ts` is 93 lines and we have none of it. When a turn ends
under `COMPLETION_THRESHOLD = 0.9` of its budget, Claude Code does not stop — it
issues `getBudgetContinuationMessage` and lets the model keep going. It stops on
`isDiminishing`: three or more continuations where both the last delta and the
current one are under `DIMINISHING_THRESHOLD = 500` tokens.

Our loop ends when the model stops. A turn that halts early halts, full stop.

**Cost:** real, and it is the quality-shaped one on this list. A model that stops
at 40% of budget on a task it could have finished is the exact failure this
mechanism exists to catch. Closing it needs a per-turn token count we already get
from `usage`, plus a nudge message and a continuation cap. Smallest real port on
this page.

### 4.3 Compaction has no tool allowlist

`microCompact.ts:41` clears results only for tools on `COMPACTABLE_TOOLS`
(read, shell, grep, glob, web search, web fetch, edit, write) — an **allowlist**,
so a tool whose result cannot be reproduced by re-running is never cleared.

`clearOldToolResults` has no such concept and clears every tool's results. Of our
six, `run` is the one that matters: re-running code is not guaranteed to
reproduce the result, because the run had side effects on the DataModel. The stub
tells the model to re-run, and for `run` that advice can be wrong.

**Cost:** low frequency, silent when it happens. Fix is a set literal and one
condition.

### 4.4 No max-output-tokens recovery loop

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

## 6. To close the last gaps

In the order I would take them:

1. **§4.2, token budget.** Self-contained, no schema or history changes, and the
   only item here that makes the agent finish more work rather than merely
   survive longer.
2. **§4.3, allowlist.** A set and a condition.
3. **§4.1, summarising compaction.** The big one, and the only one that needs a
   design: what to summarise, with which model, and how to mark the boundary so
   a restored session does not re-summarise its own summary.
4. **§4.4, recovery loop.** Only if it turns up in practice.
