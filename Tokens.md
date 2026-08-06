# How This Plugin Conserves Tokens

What is in `main/`, why, and what it still gets wrong.

## How to read this

References are by symbol, never line number — line numbers rot on the first
edit.

Claude Code comparisons come from a full clone of
`github.com/davccavalcante/claude-code-leaked`, the TypeScript exposed by a
shipped source map (the archive CLAUDE.md points at). Every upstream claim below
was grepped in that tree; where a fact is quoted, it is quoted. Three limits
apply to all of them: the archive is one snapshot, most of these constants are
GrowthBook-gated or environment-overridable, and several of the mechanisms ship
switched **off**. "Claude Code does X" here means "X is the built-in default in
that tree", not "X runs for you today".

**This is not a list of things Claude Code does.** Attribution is marked
per claim, in three flavours:

- *(theirs: `symbol`)* — verified in the clone, and we do the same thing
- **Ours.** — no upstream counterpart, or a deliberate divergence
- **Not from the source.** — reasoning or pricing from outside the archive

The unit that matters is the **turn**, not the byte. Every turn re-sends the
whole conversation, so one avoided turn is worth more than the entire tool block
costs in a session. Most of what follows is shaped by that.

---

## 1. Three cache breakpoints, all at 1 h

System prompt, last tool definition, last block of the last message. The API
caps a request at four `cache_control` blocks across system + tools + messages;
that number comes from the API's own rejection — *"A maximum of 4 blocks with
cache_control may be provided"* — not from their source, which does not state
it. Three leaves one spare.

`ttl: "1h"` needs no beta header. The archive has exactly one cache-related beta,
`PROMPT_CACHING_SCOPE_BETA_HEADER = 'prompt-caching-scope-2026-01-05'`, and it
gates the `scope` field rather than the TTL — their own comment on sending it
unconditionally reads *"The header is a no-op without a scope field."*
`getCacheControl` returns `{ type: 'ephemeral', ttl?: '1h', scope?: … }` with no
beta gate on `ttl`.

**1 h rather than 5 min.** The cache is a longest-prefix match, so a warm turn
writes only its delta while an expiry rewrites everything; the 2× write lands on
one turn's new messages, where a 5 min expiry costs a 1.25× rewrite of the whole
history. This is a plugin people leave docked while they read code, and those
gaps are exactly what expires a 5 min entry. The same TTL goes on the message
breakpoint as on system and tools *(theirs: `userMessageToMessageParam` and
`assistantMessageToMessageParam` both tag with the same
`getCacheControl({ querySource })` used for the system and tool blocks)*.

**The tagged message is copied, not mutated** (`withMessageCache`).
`conversation` is one table, appended to across turns, so tagging in place
leaves turn 1's breakpoint sitting there while turn 2 adds another — by turn 3
the request is over the four-block limit and every call fails. Copying the last
message, its block list and its last block is three small tables however long
the conversation is, and cannot accumulate. *(theirs: `addCacheBreakpoints`
rebuilds every message into a fresh `MessageParam` with
`addCache = index === markerIndex`, under the comment "Exactly one message-level
cache_control marker per request.")*

**Two guards not copied**, both listed as gaps below. Upstream, 1 h is granted
only to `USER_TYPE === 'ant'` or a subscriber **not in overage**
(`should1hCacheTTL`), *and* only when `querySource` matches a GrowthBook
allowlist (`tengu_prompt_cache_1h_config`, default `[]` — so for most users this
ships off entirely). Eligibility is then latched in session state, because
flipping TTL mid-session busts the server cache, which their comment prices at
*"~20K tokens per flip"*. **Not from the source:** the 2× / 1.25× / 0.1×
multipliers used in the reasoning above and in §5 are Anthropic's published
cache pricing; the archive states none of them.

## 2. The static prefix is small, and stable

`Tools.definitions()` emits `name`, `description`, `input_schema` and nothing
else — the registry's `run` function and aliases stay client-side. Serialized,
the whole tool block is **1 436 characters, ~359 tokens**, written once an hour.
With an empty default system prompt and a one-sentence identity line, that is
very nearly the entire static prefix.

That number is why trimming descriptions is not worth doing and why avoiding one
turn is worth more than the whole block. It is also why `defer_loading` and the
`ToolSearch` tool have no place here: upstream they exist for installs where MCP
tool definitions dominate the prefix — *"MCP tools are per-user → dynamic tool
section → can't globally cache"* — a problem six built-in tools do not have.

**Order is load-bearing.** `Tools.register` sorts modules by name because
`GetChildren()` guarantees none, so without it the block could serialise
differently between two Studio launches. Definitions render ahead of everything
else and caching is a prefix match, so a reorder invalidates the system *and*
conversation breakpoints too — a halved hit rate with no visible symptom. For
the same reason `buildTools()` appends web search **last**, so toggling it only
invalidates from the end of the tool block onward, and `Tools.definitions()`
builds fresh tables per call so a `cache_control` tag can never stick to a
shared definition.

Upstream lands on the same two moves for the same stated reason *(theirs:
`mergeAndFilterTools` — "Partition-sort for prompt-cache stability … built-ins
must stay a contiguous prefix for the server's cache policy",
`[...builtIn.sort(byName), ...mcp.sort(byName)]`)*. Sorted stable group first,
volatile group appended after: web search is to this what MCP tools are to
that.

## 3. Explanation lives in errors, not in the prompt

The most distinctive thing here. Rather than describing the shell in a tool
description, where every turn pays for it, the explanation sits in the error the
one call that needs it receives:

- an unknown command lists the real command set, derived from `HANDLERS` so it
  cannot go stale;
- `UNSUPPORTED` names why and what instead — *"chmod: instances have no
  permission bits; use the run tool to change properties"*;
- a tool name typed as a command gets *"X is a separate tool, not a shell
  command"*, asked of the registry so a tool added later is recognised the
  moment its file lands;
- an ambiguous edit gets *"old_string appears 3 times — include surrounding
  lines to make it unique; nothing was applied"*.

Each converts a wrong guess into exactly one corrective turn, at zero cost to
every turn that guessed right.

Claude Code arrives at the same pattern from the other end, rewriting schema
validation failures into instructions rather than dumping the validator's output
— *"The required parameter `x` is missing"*, *"The parameter `z` type is
expected as `string` but provided as `number`"* *(theirs:
`utils/toolErrors.ts`)*. Pushing the **whole manual** into errors is **ours**,
and is more aggressive than anything in that tree.

## 4. Tool output is capped before it goes on the wire

`forModel` / `safeCut` / `capTurn`, in `Agent.lua`.

**100 000 characters per result, head-only.** Upstream splits this by tool
because it can: `BashTool` declares `maxResultSizeChars: 30_000`, `Read` declares
`Infinity` and self-bounds at `DEFAULT_MAX_OUTPUT_TOKENS = 25000` and
`MAX_OUTPUT_SIZE` (0.25 MB), and a system-wide `Math.min` against
`DEFAULT_MAX_RESULT_SIZE_CHARS = 50_000` clamps everything else. That split is
not available here — `cat` arrives as a `bash` line, not a separate tool, and
`cat x | grep y` has no honest classification — so this takes the larger of the
two, the read budget at 4 chars per token *(theirs: `BYTES_PER_TOKEN = 4`)*.

The comparison is not as flattering as a bare 30 000-vs-100 000 makes it look,
and it cuts both ways:

- their 30 000 is a **persistence** threshold, not a truncation — past it the
  result goes to disk and the model gets a preview **plus a path**, so nothing
  is lost. Separately, `getMaxOutputLength()` truncates bash output at
  `BASH_MAX_OUTPUT_DEFAULT = 30_000`, raisable via `BASH_MAX_OUTPUT_LENGTH` up
  to `BASH_MAX_OUTPUT_UPPER_LIMIT = 150_000`;
- ours is a hard cut with nowhere to spill. So 100 000 is simultaneously the
  **looser** cap and the **lossier** one, and sits inside the range that
  codebase treats as sane.

Head rather than tail because shell output front-loads: the top of an `ls` or a
`cat` answers the question.

**200 000 characters per turn** (`capTurn`, run once after the tool loop). One
turn's `tool_result` blocks all travel in a single user message, so the
per-result cap is not a bound on its own — parallel tool use is on, and six
calls each stopping just under the cap put 600 000 characters into one message
that can never be taken back out *(theirs: the same number,
`MAX_TOOL_RESULTS_PER_MESSAGE_CHARS = 200_000`, via `getPerMessageBudgetLimit`)*.

The selection differs. Theirs replaces the **largest** fresh blocks until the
message is under budget (`selectFreshToReplace`); ours is a **smallest-first
fair share**, so a turn of three short listings and one huge `tree` spends
nearly the whole budget on the tree instead of quartering it. At 2× the
per-result cap it only binds from the third large result onward. Running after
the loop rather than inside it also means no result carries two truncation
notes.

Both get the same cache-safety property by different routes: upstream freezes a
result's fate on first sight — *"previously-unreplaced results are never
replaced later (would break prompt cache)"* — while `capTurn` only ever touches
the batch being built this turn, and never revisits history.

**The cut is UTF-8 safe.** A fixed byte offset can land mid-codepoint, and
`JSONEncode` rejects invalid UTF-8, so a careless truncation kills the request
outright. `safeCut` prefers the last newline and otherwise steps back off
continuation bytes. Only the second half is ours: the newline preference has an
exact counterpart in `generatePreview`, down to the guard stopping a short first
line from wasting the budget — `lastNewline > maxBytes * 0.5` there against
`afterNewline > limit / 2` here. The continuation-byte walk has no counterpart
because JS string slicing cannot produce invalid UTF-8; their bash truncation is
a bare `slice(0, max)`.

**The Console keeps everything.** `call.setResult()` has the full string before
this runs, so truncation is invisible on screen and only the history pays.

**The marker names the way out** — `head -n`, `tail -n`, `sed -n`, `grep` —
because otherwise the next move is to re-run the same unbounded command and pay
twice. **Ours**: upstream keeps its marker bare (`... [N lines truncated] ...`)
and puts the instruction in the cached tool prompt, which is the better trade at
30 000 chars where truncation is routine. At 100 000 it is rare, so ~40 tokens
on the rare truncation beats paying them every turn forever.

## 5. Results are small at the source

**Write and edit return summaries, not echoes.** `write` returns
`"wrote /X (12 lines)"`; `multiedit` returns
`"edited /X (2 changes, -3/+5 lines)"`. Neither echoes the source back.

What this saves is the *second* copy. The first is already in the history, as
the `tool_use` **input** on the assistant side of the pair — uncapped,
uncounted and never cleared. See gap 1, the largest hole in this file.

**`grep` groups by script** (end of `HANDLERS.grep`). DataModel paths are deep —
`/ServerScriptService/Modules/Combat/DamageHandler` is 45 characters — and the
flat `path:line: text` form repeated that on every hit. One header per script
turns ~1 800 characters of repeated path into ~430 on a 40-hit search across 6
scripts. (Worked example, not a measurement.) The grouping is a presentation
pass over `Terminal:grep`, which still returns the flat form, so `-c` and `-l`
parse what they always parsed.

**`ls` caps at 100 rows** (`MAX_LIST`). It was the one listing with no cap:
`find` and `grep` stop at `MAX_RESULTS`, but `ls /Workspace` in a place with a
few thousand parts returned all of them, stopped only by the 100 000-character
cut — by which point the result is ~25 000 tokens re-sent every remaining turn.
The cap lives in the `ls` *handler*, not in `Terminal:ls`, because `expandGlobs`
consumes that return value as a list of paths and a `… N more` sentinel would
reach `cat` as an operand.

**`ls -l` dropped its column padding and its zero counts.** `%-32s` aligns for an
eye that is not reading this, and `0 children` landed on every leaf.

All three are **ours** — upstream has no DataModel and no shell-shaped listing
layer to flatten.

## 6. Old tool results are cleared only when the cache is already cold

`clearOldToolResults`, at the top of every turn. Keeps the last 5 results
*(theirs: `keepRecent: 5`, floored at 1 because `slice(-0)` returns the whole
array)* and stubs the content of older ones.

**The trigger is cache coldness, not size** — and this is the correction that
matters most in this document, because the previous trigger was a net loss every
time it fired.

Mutating a message invalidates the cached prefix from that index onward, and the
results being cleared are the *old* ones, near the front. So a pass rewrites
essentially the whole prefix at the 1 h write rate. Priced at 50 000 tokens of
history with 20 000 cleared (**not from the source** — Anthropic's published
multipliers):

| | |
|---|---|
| the pass turn | `2.0 × 30 000` = 60 000 written, against `0.1 × 50 000` = 5 000 for the cached read it replaced |
| every later turn | `0.1 × 20 000` = 2 000 saved |
| break-even | ~28 turns, on a history that regrows past the trigger well before then |

The saving scales with what is cleared; the cost scales with the entire prefix,
so no saving floor can close the gap — only time can, and only if the session
runs ~28 more turns without re-triggering. It usually cannot: a pass drops the
history to ~120 000 chars, and the trigger fires precisely in sessions whose
tool output regrows the missing 80 000 within five to twenty turns. Payback
therefore rarely completes, and the old trigger paid at 200 000 chars — about
25 % of the context window — with a warm cache, by choice.

Nothing upstream ever pays a voluntary rewrite. All three of its paths are free:

| path | why it is free | ships |
|---|---|---|
| time-based microcompact (`evaluateTimeBasedTrigger`) | fires only past a 60-minute gap since the last assistant message, when the 1 h TTL is already expired and the prefix is being rewritten regardless | `enabled: false` |
| cached microcompact (`cachedMicrocompactPath`) | sends a `cache_edits` block deleting results server-side, leaving the cached prefix intact; reads back `cache_deleted_input_tokens` to see what it saved | ant-only, model-gated |
| autocompact (`getAutoCompactThreshold`) | fires at `contextWindow − min(maxOutput, 20 000) − 13 000` — ~84 % of a 200 k window, where the alternative is a failed request rather than a cost | on |

For a default external user, `microcompactMessages` short-circuits to *"no
compaction happens here; autocompact handles context pressure instead"*.

`cacheIsCold()` is the one of the three a plugin can have, because the TTL we
asked for is knowable client-side. Past **60 minutes** — the full TTL, not a
hair under, since anything shorter can still land on a live cache and cause
exactly the miss the gate exists to prevent — the prefix is gone anyway, so the
pass is free. Their comment states the rule: *"60 is the safe choice: the
server's 1h cache TTL is guaranteed expired for all users, so we never force a
miss that wouldn't have happened."*

`lastRequestAt` is stamped in `runTurn` beside the `streamMessage` call. Every
request routes through it, tool-loop recursions included, so a long sweep stays
correctly marked warm; `Agent.restore` clears it, since a restored session's
prefix was written by whichever session saved it.

`TRIGGER_CHARS` survives only as a cheap "is there anything here worth walking"
pre-filter. The saving floor drops to 1 on the cold path *(theirs: the guard in
that exact position is `if (tokensSaved === 0) return null` — there is no saving
floor upstream. The `20000` an earlier binary reading attached to it is
`GrepTool.maxResultSizeChars`, a cap on one tool's output.)*

`URGENT_CHARS` (600 000, ~150 000 tokens) is **ours**, and covers the case they
never face: with no summarising compaction and no disk, a history this close to
the window has to shrink even at full price. `MIN_SAVING_CHARS` applies there
and only there.

**Three rules the pass must not break**, each the difference between saving
tokens and killing the session:

- **Stub the content, never remove the block.** Every `tool_result` pairs with a
  `tool_use` already in history; drop one and every later request fails on the
  same index for the rest of the session.
- **Never write empty content.** An empty `tool_result` is rejected outright —
  the same reason `""` becomes `"(no output)"`.
- **Never replace something shorter than the stub**, or clearing costs tokens
  instead of saving them. `"(no output)"` is 11 characters and the `""` guard
  produces it routinely, so this is live rather than hypothetical. Upstream has
  no such check; `TOOL_RESULT_CLEARED_MESSAGE` is 33 characters and ours is 58
  bytes, longer because a cleared result here cannot be recovered and the stub
  has to name the way back.

Assistant messages survive, so what the model *concluded* from a cleared result
is still there — only the raw bytes go.

One upstream restriction not adopted: it clears only a fixed
`COMPACTABLE_TOOLS` set (Read, shell, Grep, Glob, WebFetch, WebSearch, Edit,
Write), so a tool whose output is small or load-bearing is never stubbed. Here
every `tool_result` is fair game — defensible while `bash`, `edit`, `write` and
`catalog` all map onto that list, and not the moment a tool is added whose
result cannot be re-derived by re-running it.

## 7. Turns are minimised where the protocol allows

Parallel tool use is left on. `runTurn` walks every `tool_use` block and returns
all results in **one** user message, which is the shape the API requires anyway,
so an `ls` + `cat` + `grep` sweep is one turn rather than three. Since a turn
re-sends the whole conversation, this is the largest single lever in the file.
`capTurn` (§4) is its counterweight — the same parallelism is the fastest way to
fill a message.

There is deliberately **no cap on the tool-use loop**. *(theirs: `maxTurns` in
`query.ts` is optional and guarded by `if (maxTurns && …)`, unset on the
interactive path and enforced only for `--max-turns`, the SDK and subagents.)* A
count of 40 was stopping real work mid-refactor. See the second gap below: one
of the original justifications for having no cap no longer holds.

## 8. The numbers are visible

Every turn prints total in (`fresh + cache read + cache write`), then cache
read, then cache write, then output. `input_tokens` alone is only the *uncached
remainder*, so once the prefix is cached the fresh part really is a couple of
tokens, and printing that number by itself made a working cache look like a
broken counter. Session totals come from `Agent.usage()`.

---

## Known gaps

Marked `ponytail:` in the source, per this repo's convention. Ordered by how
much they cost.

**1. `tool_use` inputs are unbounded and invisible.** `write` and `multiedit`
carry their payload in the **input**, not the result, and those blocks go into
`conversation` verbatim (`Agent.lua`, `block.raw`). `historyChars` counts only
`block.text` and `block.content` **strings**, so a `tool_use` scores **zero** —
`forModel`/`capTurn` cap results, and `clearOldToolResults` clears results.
A `write` the size of this repo's `Shell.lua` is 78 001 characters (~19 500
tokens) that stay for the session and that no threshold here can see, including
`URGENT_CHARS`.

**Do not "fix" this by clearing those inputs.** Upstream goes the other way, and
deliberately. Its only tool-use clearing is server-side
(`apiMicrocompact.ts`, ant-only plus `USE_API_CLEAR_TOOL_USES`), and there the
edit/write group appears as `exclude_tools: TOOLS_CLEARABLE_USES` — a
**protect** list. The constant's name reads like a target list and is not one:
`FileEdit`, `FileWrite` and `NotebookEdit` are the tools whose uses that
strategy refuses to clear, because those inputs are the record of what was
changed. The sibling strategy clears results and adds
`clear_tool_inputs: TOOLS_CLEARABLE_RESULTS` — the read and search tools, whose
inputs are a path or a pattern and cost nothing. Client-side, upstream clears no
tool-use inputs at all.

So the real difference is not selective clearing. It is that upstream bounds
total context with **autocompact** — summarising the whole history, tool_use
inputs included — and this plugin has no summarisation of any kind. That is the
structural gap; clearing write inputs is not the shortcut to it.

What is worth fixing on its own merits is the **measurement**: `URGENT_CHARS` is
the only backstop here, and it cannot see the largest thing in the history.
Counting `tool_use` inputs in `historyChars` makes that threshold measure what
it guards, reclaims nothing by itself, and changes no clearing behaviour.

**2. Nothing bounds a long uninterrupted sweep.** §7's no-cap argument leaned
partly on clearing keeping history bounded. Since §6, an active tool loop is
precisely the case that never goes 60 minutes between requests, so it never
clears — and `URGENT_CHARS`, the intended backstop, is blinded by gap 1. Fixing
gap 1 restores it.

| gap | where |
|---|---|
| Clearing touches tool results only, so a session growing on assistant text, or one with ≤5 results, is unbounded | `Agent.lua`, above `KEEP_RECENT` |
| A session held under 60 min between turns does not clear until `URGENT_CHARS`, where the rewrite is paid at full price | same |
| Cleared output is unrecoverable; a plugin has nowhere to spill | same |
| `capTurn` can compute a negative share once truncation markers overshoot enough budget, and `string.sub(s, 1, negative)` slices from the **end** — latent, needs an implausible number of parallel calls in one turn | `Agent.lua`, `capTurn` |
| `tree` and `du` are bounded only by the per-result cap | `Agent.lua`, above `MODEL_RESULT_CHARS` |
| No overage gating, allowlist or session latch on the 1 h TTL (§1) | `Claude.lua`, `withMessageCache` |
| `grep` grouping costs per-line file attribution when piped into another `grep` | `Shell.lua`, end of `HANDLERS.grep` |

The upgrade path for the clearing gaps is summarising compaction — replacing
spans of history with a paragraph rather than only blanking results. Upstream
sizes that off the model's context window rather than a char constant
(`AUTOCOMPACT_BUFFER_TOKENS = 13_000`) and carries
`MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3`, which guards against retrying a
compaction that keeps *failing* — not against re-triggering one that keeps
succeeding. Nothing upstream guards the latter; the cold-cache gate is what
makes it a non-issue here.

## Examined and not adopted

- **Spilling large results to disk** — no filesystem. This is the single biggest
  capability gap between the two: it is what lets upstream cap harder than we do
  while losing nothing.
- **`defer_loading` / `ToolSearch`** — see §2.
- **`bytesPerTokenForFileType`**, which estimates JSON at 2 chars per token
  rather than 4 — this plugin reads real usage off the response instead of
  estimating.

**Still open: server-side `context_management`.** `apiMicrocompact.ts` is the
shape of it — strategy `clear_tool_uses_20250919`, beta header
`context-management-2025-06-27`, gated on `USER_TYPE === 'ant'` plus
`USE_API_CLEAR_TOOL_RESULTS` / `USE_API_CLEAR_TOOL_USES`, with
`DEFAULT_MAX_INPUT_TOKENS = 180_000` triggering and
`DEFAULT_TARGET_INPUT_TOKENS = 40_000` kept — a trigger near the window, not an
early one. It would move clearing to the API so it stops invalidating the cached
prefix, letting it run warm and collapsing the second gap above. Untried; needs
a live request to learn whether OAuth accepts the beta.

## Open decisions

Judgement calls, not oversights.

**`run` is offered even while disabled.** `Settings.allowRun` defaults false and
the guard is in `Terminal:run`, but `buildTools()` offers the tool every turn, so
each attempt costs a turn. Filtering it out is not a clean win: the error —
*"enable it in Settings > Run code"* — is the only thing that tells the user the
capability exists, and `isSeparateTool` asks the registry, so `bash` would still
claim *"run is a separate tool"* for a tool no longer offered.

**Two comments describe behaviour the code lacks.** `tools/bash.lua` says its
description *"carries the MAPPING … that this filesystem is a DataModel"* — the
description is *"rely on this using bash commands to explore the file system"*
and says no such thing. And `Terminal:run` justifies having no timeout with
*"The tool description tells Claude to bound its loops"* — `tools/run.lua`
states the hazard but never gives the instruction. The second is worth ~10
tokens to fix regardless, since the failure mode is Studio freezing.

**`write` and `bash`'s `>` are one operation behind two doors.**
`applyRedirect` calls the same `Terminal:write` the `write` tool calls, and
nothing tells the model which to prefer. `edit.lua` knows the answer — shell
quoting eventually corrupts source — it just never says it anywhere the model
reads. Remove neither: `>` is what lets pipelines terminate, `write` is what
keeps Luau source out of the tokenizer.

**Rejected: merging `edit` into `multiedit`.** `Terminal:edit` is already
`multiedit(path, {one})`, so there is no duplicated logic to remove — only 267
characters of schema. Forcing every single-hunk edit to carry an `edits` array
walks into the documented failure where a long payload truncated by `max_tokens`
arrives as invalid JSON and poisons the history.

## Checks

`Agent.selfTest()` and `Shell.selfTest()`, wired into `main.lua` beside the
Markdown, Terminal and Props self-tests.

Agent covers the truncation shape, the UTF-8 boundary, the line-boundary cut,
and `capTurn` in both directions — a normal sweep must come back
byte-identical, a flood of oversized results must land inside the turn budget
with no empty block, and a lone large result must not be starved by small
siblings. For §6: pairing preserved, no empty content, recent results untouched,
idempotent, small history left alone.

All three sides of the cache gate are covered, because each fails silently — an
oversized history on a **cold** cache must clear, the same history **warm** must
not, and a warm history past `URGENT_CHARS` must clear anyway. The warm fixture
is sized so the old saving floor would have let it through, which is what makes
it a test of the gate rather than of the floor. The tests drive `lastRequestAt`
directly and restore it.

Shell covers the `ls` cap and its row count, `ls -l` emitting no zero counts,
and `grep` emitting one header per script while `-c` and `-l` still read the
ungrouped form.

Fixture sizes derive from `MODEL_RESULT_CHARS`, `MAX_LIST`, `TRIGGER_CHARS` and
`URGENT_CHARS` rather than being written as literals, so moving a threshold
cannot silently stop the tests exercising anything — and here that matters
twice, since the warm fixture has to stay *between* two of them.
