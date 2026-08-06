# How This Plugin Conserves Tokens

What is actually in `main/`, and why.

References are by symbol, not line number — line numbers rot on the first edit,
and several in an earlier draft already pointed at the wrong code.

Comparisons to Claude Code are read from its TypeScript source, exposed by a
source map shipped to npm and archived at
`github.com/davccavalcante/claude-code-leaked` (the v2.1.88 sourcemap CLAUDE.md
points at). An earlier pass read the shipped binary instead, which gets
constants right and the mangled control flow around them wrong: **three claims
here were wrong until the source settled them** (§1, §7, and the no-such-floor
note below). Two limits remain — the archive is one snapshot, and most of these
constants are GrowthBook-gated or environment-overridable, so they are built-in
defaults, several of which ship switched off.

**Do not read this as a list of things Claude Code does.** Most of it is this
repo's own design:

| | |
|---|---|
| Borrowed, verified in source | keeping the last 5 tool results and stubbing older ones, and clearing them only when the cache is already cold (§7); head-only truncation with a marker; preferring the last newline, with the same half-the-budget guard (§6); the read-versus-shell budget split and the 4-chars-per-token estimator behind §6; a per-*message* budget on top of the per-result one (§6); the same `cache_control`, 1 h TTL included, on the message breakpoint as on system and tools, and rebuilding rather than mutating so exactly one lands (§1); rewriting schema-validation failures into instructions (§4) |
| This repo's | the three-breakpoint scheme (§1); tool ordering as a cache concern (§2); minimal tool definitions (§3); putting the manual in the error rather than the prompt (§4), which is more aggressive than anything Claude Code does; parallel tool use (§8); per-file rather than per-line listings (§9); the usage line (§10) |
| Derived here, not quoted | the 100 000-char cap (25 000 tokens × 4; their read byte cap is `MAX_OUTPUT_SIZE`, 256 KB, and their system-wide default is `DEFAULT_MAX_RESULT_SIZE_CHARS`, 50 000 — looser here because we truncate where they spill to disk); `URGENT_CHARS` (§7); `safeCut`'s continuation-byte walk, which has no counterpart because JS string slicing cannot produce invalid UTF-8 |

One correction worth keeping visible, because the number is still out there:
**there is no floor on how little a clearing pass may save.** Claude Code's
guard is `if (tokensSaved === 0) return null`. The `20000` the binary reading
attached to it is `GrepTool.maxResultSizeChars`, a cap on one tool's output.

The unit that matters here is the **turn**, not the byte. Every turn re-sends
the whole conversation, so one avoidable turn costs more than the entire tool
block does in a session. Most of what follows is shaped by that.

---

## 1. Three cache breakpoints, placed deliberately

Anthropic caps a request at four `cache_control` blocks across system, tools and
messages combined. This uses three — system prompt, last tool definition, and
the last block of the last message — **all at 1 h**. `ttl` needs no beta header;
there is no cache-related beta string anywhere in Claude Code's source, which is
also what makes the TTL real rather than a field the API quietly ignores.

The conversation breakpoint sat on 5 min until the source settled it; the
argument is in `withMessageCache` and comes down to the cache being a
longest-prefix match, so a warm turn writes only its delta while an expiry
rewrites everything. Claude Code agrees — `userMessageToMessageParam` and
`assistantMessageToMessageParam` tag the message breakpoint with the *same*
`getCacheControl({ querySource })` the system and tool blocks use.

Two details not copied, both marked as ceilings: eligibility is
`USER_TYPE === 'ant'` or a subscriber **not in overage** — a 1 h write costs 2×
base against 5 min's 1.25×, and that is quota, so they stop paying it when quota
is tight — and the choice is latched per session, because flipping TTL
mid-session busts the server cache, which their comment prices at ~20 k tokens.
(Those multipliers are Anthropic's published cache pricing; the source states
neither.)

**The tagged message is copied, not mutated** (`withMessageCache`). The
conversation is the same table across turns and only ever appended to, so
tagging the last block in place leaves turn 1's breakpoint sitting there while
turn 2 adds another; by turn 3 the request is over the four-block limit and
every call fails with *"A maximum of 4 blocks with cache_control may be
provided."* Copying the last message, its block list and its last block — three
small tables, however long the conversation — cannot accumulate a tag. Claude
Code solves it the same way and for the same reason: `addCacheBreakpoints` maps
the whole history into fresh `MessageParam`s each request with
`addCache = index === markerIndex`, and its comment states the invariant
outright — *"Exactly one message-level cache_control marker per request."*

## 2. Tool order is load-bearing

`Tools.register` sorts the tool modules by name. `GetChildren()` guarantees no
order, so without the sort the tool block could serialise differently between
two Studio launches. Caching is a prefix match and tool definitions render ahead
of everything else, so a reorder invalidates the system *and* conversation
breakpoints too — a silently halved hit rate with no visible symptom.

For the same reason `buildTools()` appends web search **last**, so toggling it
only invalidates from the end of the tool block onward, and `Tools.definitions()`
builds fresh tables per call so a `cache_control` tag can never persist onto a
shared definition.

## 3. Only what the API reads is sent

`Tools.definitions()` emits `name`, `description` and `input_schema` and nothing
else; the registry's own fields — the `run` function, aliases — stay client-side.

The whole tool block is **1 436 characters, ~360 tokens**, written once an hour.
The default system prompt is empty and the identity line is one sentence, so
that is very nearly the entire static prefix. This is the number that makes
trimming descriptions pointless and makes avoiding a single turn worth ~8× more.
It is also why Claude Code's `defer_loading` / tool-search machinery has no
place here: it exists for installs where MCP tool descriptions pass 10 % of the
context window.

## 4. Explanation lives in errors, not in the prompt

The most distinctive thing in this codebase. Rather than describing the shell in
the tool description — where every turn pays for it — the explanation sits in
the error that the one call needing it receives:

- Unknown command lists the entire real command set, derived from `HANDLERS` so
  it cannot go stale.
- `UNSUPPORTED` names *why* and *what instead*: *"chmod: instances have no
  permission bits; use the run tool to change properties"*.
- A tool name typed as a command gets *"X is a separate tool, not a shell
  command"*, asked of the registry so a tool added later is recognised the
  moment its file lands.
- Ambiguous edits get *"old_string appears 3 times — include surrounding lines
  to make it unique; nothing was applied"*.

Each turns a wrong guess into exactly one corrective turn, at zero cost to the
turns that guessed right. Claude Code reaches the same pattern from the other
direction, rewriting schema-validation failures into instructions — *"The
required parameter `x` is missing"*, *"The parameter `z` type is expected as
`string` but provided as `number`"* (`utils/toolErrors.ts`) — rather than
dumping the validator's own error.

## 5. Tool results are summaries, not echoes

`write` returns `"wrote /X (12 lines)"`; `multiedit` returns `"edited /X
(2 changes, -3/+5 lines)"`. Neither echoes the source it just wrote — the model
already has it, and the file is one `cat` away if it does not.

## 6. Tool output is capped before it goes on the wire

`forModel` / `safeCut` / `capTurn`, in `Agent.lua`.

**100 000 characters per result, head-only.** Claude Code caps shell output at
30 000 chars but gives file reads 25 000 tokens; that split is not available
here because `cat` arrives as a `bash` line rather than a separate tool, so this
takes the larger of the two — the read budget at 4 chars per token. Their 30 000
is itself a default, raisable via `BASH_MAX_OUTPUT_LENGTH` as far as
`BASH_MAX_OUTPUT_UPPER_LIMIT = 150_000`, so 100 000 sits inside the range the
same codebase treats as sane. Head rather than tail because shell output
front-loads: the top of an `ls` or a `cat` answers the question.

**200 000 characters per turn.** `capTurn` runs once after the tool loop. One
turn's `tool_result` blocks all travel in a single user message, so the
per-result cap alone is not a bound — parallel tool use is on, and six calls
that each stop just under the cap put 600 000 characters into one message that
can never be taken back out. Claude Code caps the same thing
(`MAX_TOOL_RESULTS_PER_MESSAGE_CHARS = 200_000`) and spills the largest blocks
to a file, handing the model a path; with nowhere to spill, the big ones are cut
harder instead. The split is smallest-first fair share, so a turn of three short
listings and one huge `tree` spends nearly the whole budget on the tree rather
than quartering it, and at 2× the per-result cap it only binds from the third
large result onward. After the loop rather than inside it, so no result ends up
carrying two truncation notes.

**The cut is UTF-8 safe.** A fixed byte offset can land mid-codepoint and
`JSONEncode` rejects invalid UTF-8, so a careless truncation kills the request
outright. `safeCut` prefers the last newline (always a codepoint boundary, and a
tidier stop) and otherwise steps back off continuation bytes.

Only the second half is ours. The newline preference has an exact counterpart in
`generatePreview` (`toolResultStorage.ts`), down to the guard that stops a short
first line from throwing away the budget — `lastNewline > maxBytes * 0.5` there
against `afterNewline > limit / 2` here. The continuation-byte walk has none,
because JS string slicing cannot produce invalid UTF-8; upstream bash truncation
is a bare `slice(0, max)`.

**The Console keeps everything.** `call.setResult()` has already been handed the
full string by the time this runs, so truncation is invisible to the user and
only the history pays.

**The message names the way out** — `head -n`, `tail -n`, `sed -n`, `grep` —
because otherwise the model's next move is to re-run the same unbounded command
and pay for it twice.

> Claude Code puts that instruction in the cached tool prompt instead and keeps
> its marker bare — the better trade at 30 000 chars, where truncation is
> routine. At 100 000 it is rare, so ~40 tokens on the rare truncation beats
> paying them every turn forever.

## 7. Old tool results are cleared in place

`clearOldToolResults`, run at the top of every turn. Keeps the last 5 tool
results and replaces the content of older ones with a stub.

Keeping 5 is Claude Code's shape (`keepRecent: 5`, floored at 1 because
`slice(-0)` returns the whole array). So, now, is the trigger — **it fires on
cache coldness, not on size.**

The earlier trigger was two size thresholds (200 000 chars of history, 80 000
saved) and it was wrong in a way no threshold could fix. Mutating a message
invalidates the cache from that index onward, and cleared results are the *old*
ones, sitting near the front — so a pass re-writes essentially the whole prefix
at the 1 h write rate. Priced at 50 000 tokens of history with 20 000 cleared:

| | |
|---|---|
| pass turn | `2.0 × 30 000` written = 60 000, against `0.1 × 50 000` = 5 000 for the cached read it replaced |
| later turns | `0.1 × 20 000` = 2 000 saved each |
| break-even | ~28 turns, on a session that re-crosses the trigger long before that |

The saving scales with what is cleared. The cost scales with the whole prefix.
No saving floor closes that gap, which is why this was a net loss whenever it
fired — and it fired at ~25 % of the context window, with a warm cache, by
choice.

Claude Code never pays a voluntary re-write. All three of its paths are free:
**time-based microcompact** fires only when the gap since the last assistant
message exceeds 60 minutes, at which point the 1 h TTL is guaranteed expired and
the prefix is being re-written regardless (`evaluateTimeBasedTrigger`; ships
`enabled: false`); **cached microcompact** sends a `cache_edits` block that
deletes results server-side and leaves the cached prefix intact, reading back
`cache_deleted_input_tokens` to find out what that saved; **autocompact** fires
near the window limit, where the alternative is a failed request rather than a
cost.

`cacheIsCold()` is the one of those three a plugin can have, because the TTL we
asked for is knowable client-side: past 60 minutes since the last request the
prefix is gone anyway, so clearing first is free. `TRIGGER_CHARS` survives as a
cheap "is there anything here worth walking" pre-filter, and the saving floor
drops to 1 on the cold path — the same guard Claude Code has in that position
(`if (tokensSaved === 0) return null`; there is no saving floor upstream, and
the `20000` an earlier reading attached to it is `GrepTool.maxResultSizeChars`).

`URGENT_CHARS` (600 000, ~150 000 tokens) is the case they do not have to
handle. With nowhere to spill and no summarising compaction, a history that
close to the window has to shrink even at full price, because the alternative is
the session ending. `MIN_SAVING_CHARS` applies there and only there.

The other half of the fix is knowing when the last request went out.
`lastRequestAt` is stamped in `runTurn` beside the `streamMessage` call — every
request comes through it, tool-loop recursions included, so a long sweep keeps
the cache correctly marked warm — and `Agent.restore` clears it, since a
restored session's prefix was last written by whichever session saved it.

One thing it does that this plugin does not: it only clears results from a fixed
set of tools (`COMPACTABLE_TOOLS` — Read, shell, Grep, Glob, WebFetch,
WebSearch, Edit, Write), so a tool whose output is small or load-bearing is
never stubbed. Here every `tool_result` is fair game, which is defensible while
the tools are what they are — `bash`, `edit`, `write` and `catalog` all map onto
that list — and stops being defensible the moment a tool is added whose result
the model cannot re-derive by re-running it.

Three rules it must not break, all of them the difference between saving tokens
and killing the session:

- **Stub the content, never remove the block.** Every `tool_result` pairs with a
  `tool_use` already in the history; drop one and every later request fails on
  the same index for the rest of the session.
- **Never write empty content.** An empty `tool_result` is rejected outright —
  the same reason `""` becomes `"(no output)"`.
- **Never replace something shorter than the stub**, or clearing costs tokens
  instead of saving them. `"(no output)"` is 11 characters and the `""` guard
  produces it routinely, so this is live rather than hypothetical. Claude Code
  has no such check; its stub is 33 characters.

What survives: the assistant's own messages. So what the model *concluded* from
a cleared result is still there — only the raw bytes go.

## 8. Turns are minimised where the protocol allows

Parallel tool use is left on. `runTurn` walks every `tool_use` block and returns
all results in **one** user message, which is the shape the API requires anyway
— so an `ls` + `cat` + `grep` sweep is one turn rather than three. Since a turn
re-sends the whole conversation, turns are the expensive unit and this is the
largest single lever in the file. `capTurn` (§6) is the counterweight: the same
parallelism is also the fastest way to fill a message.

## 9. Listings pay once per file, not once per line

Three shapes in the terminal output cost per *row* what they only owe per
*container*. None of the three loses information.

**`grep` groups by script** (end of `HANDLERS.grep`). DataModel paths are deep —
`/ServerScriptService/Modules/Combat/DamageHandler` is 45 characters — and the
flat `path:line: text` form repeated that on every hit. One header per script;
on a 40-hit search across 6 scripts that is ~430 characters of path where the
flat form spent ~1800. (Worked example, not a measurement.) The grouping is a
presentation pass on top of `Terminal:grep`, which still returns the flat form,
so `-c` and `-l` parse what they always parsed.

**`ls` is capped at 100 rows** (`MAX_LIST`). It was the one listing with no cap:
`find` and `grep` stop at `MAX_RESULTS`, but `ls /Workspace` in a place with a
few thousand parts returned every one of them, stopped only by `forModel`'s
100 000-character cut — by which point the result is ~25 000 tokens re-sent on
every remaining turn. The cap lives in the `ls` *handler* rather than in
`Terminal:ls`, because `expandGlobs` consumes that return value as a list of
paths and a `… N more` sentinel would arrive at `cat` as an operand.

**`ls -l` dropped its column padding and its zero counts.** `%-32s` aligns for
an eye that is not reading this, and `0 children` landed on every leaf.

## 10. The numbers are visible

Every turn prints fresh / cached / written / output tokens, because
`input_tokens` alone is only the *uncached remainder* — once the prefix is
cached the fresh part really is a couple of tokens, and printing that number by
itself made a working cache look like a broken counter. `/context`-equivalent
session totals come from `Agent.usage()`.

---

## Known ceilings

Marked with `ponytail:` in the source, per this repo's convention.

| ceiling | where |
|---|---|
| Clearing only touches tool results — a session that grows on assistant text, or one with ≤5 results, is still unbounded | `Agent.lua`, above `KEEP_RECENT` |
| A session held under 60 min between turns never clears until it reaches `URGENT_CHARS`, where the re-write is paid at full price | same |
| Cleared output is unrecoverable; a plugin has nowhere to spill it | same |
| `tree` and `du` are still bounded only by the per-result cap | `Agent.lua`, above `MODEL_RESULT_CHARS` |
| No overage gating or session latch on the 1 h TTL | `Claude.lua`, `withMessageCache` |
| `grep` grouping costs per-line file attribution when piped into another `grep` | `Shell.lua`, end of `HANDLERS.grep` |

Upgrade path for the first two is summarising compaction — replacing spans of
history with a paragraph instead of only blanking results. Claude Code's version
sizes its threshold off the model's context window rather than a char constant
(`getAutoCompactThreshold`, `AUTOCOMPACT_BUFFER_TOKENS = 13_000`) and carries a
`MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3` circuit breaker — which guards
against retrying a compaction that keeps *failing*, not against re-triggering
one that keeps succeeding. Nothing upstream guards the latter; the cold-cache
gate is what makes it a non-issue here.

## Not adopted, deliberately

Mechanisms in the source that were examined and left alone, so nobody re-derives
them: **spilling large results to disk** (no filesystem, and with the caps in §6
and §9 almost nothing reaches the threshold); **`defer_loading` / tool search**
(§3 — the whole tool block is ~360 tokens); **`bytesPerTokenForFileType`**,
which estimates JSON at 2 chars per token rather than 4 (this plugin reads real
usage off the response instead of estimating).

Still open: **server-side `context_management`** (`clear_tool_uses_20250919`),
which would move clearing to the API and stop it invalidating the cached prefix,
so it could run on a warm cache and collapse the second ceiling above.
`apiMicrocompact.ts` is the shape of it — `USER_TYPE === 'ant'` plus
`USE_API_CLEAR_TOOL_RESULTS`, with `DEFAULT_MAX_INPUT_TOKENS = 180_000` as the
trigger and `DEFAULT_TARGET_INPUT_TOKENS = 40_000` kept. Untried; needs a live
request to know whether OAuth accepts the beta.

## Open decisions

Three judgement calls, not oversights.

**`run` is offered even while disabled.** `Settings.allowRun` defaults false and
the guard is in `Terminal:run`, but `buildTools()` offers the tool every turn, so
each attempt is a wasted turn. Filtering it out is not a clean win: the error it
returns — *"enable it in Settings > Run code"* — is the only thing that ever
tells the user the capability exists, and `isSeparateTool` asks the registry, so
`bash` would still claim *"run is a separate tool"* for a tool no longer offered.

**Two comments describe behaviour the code lacks.** `tools/bash.lua` says its
description *"carries the MAPPING … that this filesystem is a DataModel"* — it
does not. And `Terminal:run` justifies having no timeout with *"The tool
description tells Claude to bound its loops"* — `tools/run.lua` states the
hazard but never gives the instruction. The second is worth ~10 tokens to fix
regardless, since the failure mode is Studio freezing.

**`write` and `bash`'s `>` are one operation behind two doors.** `applyRedirect`
calls the same `Terminal:write` the `write` tool calls, and nothing tells the
model which to prefer. `edit.lua` already knows the answer — shell quoting
eventually corrupts source — it just never says it anywhere the model reads.
Remove neither: `>` is what lets pipelines terminate, `write` is what keeps Luau
source out of the tokenizer.

Also considered and rejected: merging `edit` into `multiedit`. `Terminal:edit`
is already `multiedit(path, {one})`, so there is no duplicated logic to remove,
only ~267 chars of schema — and forcing every single-hunk edit to carry an
`edits` array walks straight into the documented failure where a long payload
truncated by `max_tokens` arrives as invalid JSON and poisons the history.

## Checks

`Agent.selfTest()` and `Shell.selfTest()`, wired into `main.lua` alongside the
Markdown, Terminal and Props self-tests.

Agent covers the truncation shape, the UTF-8 boundary, the line-boundary cut,
`capTurn` in both directions (a normal sweep must come back byte-identical, a
flood of oversized results must land inside the turn budget with no empty
block, and a lone large result must not be starved by small siblings), and every
rule in §7 — pairing preserved, no empty content, recent results untouched,
idempotent, small history left alone.

All three sides of the cache gate are covered, because each fails silently: an
oversized history on a **cold** cache must clear, the same history **warm** must
not (this is the whole point of the change, and the fixture is sized so the old
saving floor would have let it through), and a warm history past
`URGENT_CHARS` must clear anyway. The tests drive `lastRequestAt` directly and
restore it.

Shell covers the `ls` cap and its row count, `ls -l` emitting no zero counts,
and `grep` emitting one header per script while `-c` and `-l` still read the
ungrouped form.

Fixture sizes derive from `MODEL_RESULT_CHARS`, `MAX_LIST`, `TRIGGER_CHARS` and
`URGENT_CHARS` rather than being written as literals, so moving a threshold
cannot silently stop the tests exercising anything — and here it matters twice,
since the warm fixture has to stay *between* two of them.
