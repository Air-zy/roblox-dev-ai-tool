# How This Plugin Conserves Tokens

What is actually in `main/`, and why.

Comparisons to Claude Code throughout were taken from the shipped binary
(v2.1.221, `~/.local/share/claude/versions/`), whose bundled JS is stored as
plaintext and can be read with
`tr -c '\11\12\15\40-\176' '\n' < <binary> | grep -av '^.\{0,7\}$'`. There is no
public source repo for it — the GitHub one carries issues, docs and plugins,
not the CLI.

Two limits on that evidence. It is one version, and several of the constants
are read through gated lookups (`Je("tengu_…", default)`) or environment
overrides, so the figures quoted are **built-in defaults**, not necessarily
what any given install runs. And the bundle is minified: string and numeric
constants are unambiguous, but the control flow around them was read from
mangled identifiers.

**Do not read this as a list of things Claude Code does.** Most of it is this
repo's own design, and the two differ more than they overlap:

| | |
|---|---|
| Borrowed, verified against the binary | keeping the last 5 tool results and stubbing older ones (`H2p=5`, `[Old tool result content cleared]`); a floor on how little a clearing pass may save (`Uzs=20000`); head-only truncation with a marker; the read-versus-shell budget split (`Ro_=25000` vs `igs=30000`) and the 4-chars-per-token estimator (`Ton=4`) behind §6's number; rewriting schema-validation failures into instructions |
| This repo's, predating any of this work | the three-breakpoint cache scheme and the strip-then-retag in §1 — Claude Code uses up to two message breakpoints and rebuilds the array rather than mutating one; tool ordering as a cache concern (§2); putting the manual in the error rather than the prompt (§4), which is more aggressive than anything Claude Code does; minimal tool definitions (§3); parallel tool use (§8); the usage line (§9) |
| Derived here, not quoted from anywhere | the 100 000-char cap (25 000 tokens × 4, not a constant of theirs — their byte cap is 262 144); the 200 000 / 80 000 clearing thresholds, where Claude Code instead triggers off a server context hint or context pressure; `safeCut`'s UTF-8 handling, which has no counterpart because JS string slicing cannot produce invalid UTF-8 |

The unit that matters here is the **turn**, not the byte. Every turn re-sends
the whole conversation, so one avoidable turn costs more than the entire tool
block does in a session. Most of what follows is shaped by that.

---

## 1. Three cache breakpoints, placed deliberately

Anthropic caps a request at four `cache_control` blocks across system, tools
and messages combined. This uses three.

| block | TTL | where |
|---|---|---|
| system prompt (last block) | 1 h | `Claude.lua:231` |
| tool definitions (last tool) | 1 h | `Claude.lua:248` |
| conversation (last block of last message) | 5 min | `Claude.lua:149` |

The first two are small and static, so an hour costs one write per hour. The
third moves every turn, which is why `Claude.lua:224-230` leaves it on the
default TTL — see the open decision at the bottom of this file, which disputes
that.

**The breakpoint on the conversation is stripped before it is re-applied**
(`applyMessageCache`, `Claude.lua:136-155`). `conversation` is the same table
across turns and is only ever appended to, so tagging the last block without
clearing the previous tag leaves turn 1's breakpoint in place while turn 2 adds
another. By turn 3 the request is over the four-block limit and every call
fails with *"A maximum of 4 blocks with cache_control may be provided."*

## 2. Tool order is load-bearing

`Tools.lua:31-35` sorts the tool modules by name before registering them.
`GetChildren()` guarantees no order, so without the sort the tool block could
serialise differently between two Studio launches. Caching is a prefix match
and tool definitions render ahead of everything else, so a reorder invalidates
the system *and* conversation breakpoints too — a silently halved hit rate with
no visible symptom.

For the same reason `buildTools()` (`Agent.lua:84-91`) appends web search
**last**, so toggling it only ever invalidates from the end of the tool block
onward, and `Tools.definitions()` builds fresh tables per call so a
`cache_control` tag can never persist onto a shared definition.

## 3. Only what the API reads is sent

`Tools.definitions()` (`Tools.lua:58-68`) emits `name`, `description` and
`input_schema` and nothing else. The registry's own fields — the `run`
function, aliases — stay client-side.

The whole tool block is **1 436 characters, ~360 tokens**, written to cache
once an hour. The default system prompt is empty (`Settings.lua:32`) and the
identity line is one sentence, so that is very nearly the entire static prefix.
This is the number that makes trimming descriptions pointless and makes
avoiding a single turn worth ~8× more.

## 4. Explanation lives in errors, not in the prompt

The most distinctive thing in this codebase. Rather than describing the shell
in the tool description — where every turn pays for it — the explanation sits
in the error that the one call needing it receives:

- Unknown command lists the entire real command set (`Shell.lua:1154`),
  derived from the `HANDLERS` table so it cannot go stale.
- `UNSUPPORTED` (`Shell.lua:287-298`) names *why* and *what instead*:
  *"chmod: instances have no permission bits; use the run tool to change
  properties"*, *"awk: use the run tool"*.
- A tool name typed as a command gets *"X is a separate tool, not a shell
  command"* (`Shell.lua:1148`), asked of the registry so a tool added later is
  recognised the moment its file lands.
- Ambiguous edits get *"old_string appears 3 times — include surrounding lines
  to make it unique; nothing was applied"* (`Terminal.lua:508`).

Every one of those turns a wrong guess into exactly one corrective turn, at
zero cost to the turns that guessed right. Claude Code arrives at the same
pattern from the other direction, rewriting schema-validation failures into
instructions — *"The required parameter `x` is missing"*, *"The parameter `z`
type is expected as `string` but provided as `number`"* — rather than dumping
the validator's own error.

## 5. Tool results are summaries, not echoes

`write` returns `"wrote /X (12 lines)"`; `multiedit` returns
`"edited /X (2 changes, -3/+5 lines)"` (`Terminal.lua:463,524`). Neither echoes
the source it just wrote — the model already has it, and the file is one `cat`
away if it does not.

## 6. Tool output is capped before it goes on the wire

`forModel` / `safeCut` (`Agent.lua:65-102`), applied at `Agent.lua:562`.

**100 000 characters, head-only.** Claude Code caps shell output at 30 000
chars but gives file reads 25 000 tokens; that split is not available here
because `cat` arrives as a `bash` line rather than a separate tool, so this
takes the larger of the two. 100 000 chars is that read budget at 4 chars per
token.

Head rather than tail because shell output front-loads — the top of an `ls` or
a `cat` answers the question.

**The cut is UTF-8 safe.** A fixed byte offset can land mid-codepoint and
`JSONEncode` rejects invalid UTF-8, so a careless truncation kills the request
outright. `safeCut` prefers the last newline (always a codepoint boundary, and
a tidier stop) and otherwise steps back off continuation bytes.

No counterpart exists upstream: Claude Code slices UTF-16 JS strings, which
cannot produce invalid UTF-8, so its bash truncation is a bare
`slice(0, 30000)`. This half is Lua's problem alone.

**The Console keeps everything.** `call.setResult()` has already been handed
the full string by the time this runs (`Agent.lua:382`), so truncation is
invisible to the user and only the history pays.

**The message names the way out** — `head -n`, `tail -n`, `sed -n`, `grep` —
because otherwise the model's next move is to re-run the same unbounded
command and pay for it twice.

> Claude Code splits this differently: its marker is bare
> (`... [N lines truncated] ...`) and the instruction lives in the cached tool
> prompt — *"If you receive truncation warnings … reduce the chunk size … Bash
> output is limited to N chars."* That is the better trade at a 30 000-char cap
> where truncation is routine. At 100 000 it is rare, so paying ~40 tokens on
> the rare truncation beats paying them on every turn forever.

## 7. Old tool results are cleared in place

`clearOldToolResults` (`Agent.lua:264-303`), run at the top of every turn.

Keeps the last 5 tool results, replaces the content of older ones with a stub,
and only acts once the history passes 200 000 chars *and* the pass would save
at least 80 000. Both thresholds exist because mutating a message invalidates
the cache from that index onward, so every pass costs one full prefix re-write.

Keeping 5 and stubbing the rest is Claude Code's shape. The trigger is not:
it clears on a context hint from the server or on context pressure, with a
20 000-token floor on how little a pass may save. A fixed history size is the
version available to a plugin that cannot see how full the window is.

Three rules it must not break, all of them the difference between saving tokens
and killing the session:

- **Stub the content, never remove the block.** Every `tool_result` pairs with
  a `tool_use` already in the history; drop one and every later request fails
  on the same index for the rest of the session.
- **Never write empty content.** An empty `tool_result` is rejected outright —
  the same reason `""` becomes `"(no output)"` at `Agent.lua:381`.
- **Never replace something shorter than the stub**, or clearing costs tokens
  instead of saving them. `"(no output)"` is 11 characters and the `""` guard
  produces it routinely, so this is a live case rather than a hypothetical.
  Claude Code has no equivalent check — its stub is 33 characters and it
  computes savings in tokens — so keeping ours short (58 bytes) is what keeps
  the guard incidental instead of load-bearing.

What survives: the assistant's own messages. So what the model *concluded* from
a cleared result is still there — only the raw bytes go.

## 8. Turns are minimised where the protocol allows

Parallel tool use is left on (`Claude.lua:250-256`). `runTurn` walks every
`tool_use` block and returns all results in **one** user message, which is the
shape the API requires anyway — so an `ls` + `cat` + `grep` sweep is one turn
rather than three. Since a turn re-sends the whole conversation, turns are the
expensive unit and this is the largest single lever in the file.

## 9. The numbers are visible

Every turn prints fresh / cached / written / output tokens
(`Agent.lua:432-453`), because `input_tokens` alone is only the *uncached
remainder* — once the prefix is cached the fresh part really is a couple of
tokens, and printing that number by itself made a working cache look like a
broken counter.

`/context`-equivalent totals for the session come from `Agent.usage()`.

---

## Known ceilings

Marked with `ponytail:` in the source, per this repo's convention.

| ceiling | where |
|---|---|
| Clearing only touches tool results — a session that grows on assistant text, or one with ≤5 results, is still unbounded | `Agent.lua`, above `KEEP_RECENT` |
| No anti-thrash breaker; a heavy session can re-cross the trigger every few turns, paying a prefix re-write each time | same |
| Trigger is eager — 200 000 chars is ~25 % of the window, so re-writes start well before the session is at risk | same |
| Cleared output is unrecoverable; a plugin has nowhere to spill it | same |
| One result cap for reads and listings alike, so `ls -R /` may now spend 100 000 chars | `Agent.lua`, above `MODEL_RESULT_CHARS` |

Upgrade path for the first three is summarising compaction — replacing spans of
history with a paragraph instead of only blanking results.

## Open decisions

Four things examined and deliberately left alone. Each is a judgement call, not
an oversight.

**1 h TTL on the conversation breakpoint.** `Claude.lua:224-230` argues the
conversation breakpoint should stay at 5 min because *"it moves and grows every
turn, so doubling its write cost would swamp the saving."* That holds only if
each turn re-writes the whole conversation — it does not, while the cache is
warm, because the lookup is a longest-prefix match, so turn N+1 reads turn N's
entry and writes only the delta. The doubled cost lands on one turn's new
messages; a 5 min expiry costs a full re-write of everything. On a 60 k-token
thread that is roughly a 6 k-token read versus a 75 k-token write on the first
turn back after a pause — and this is a plugin people leave docked while they
think. It is one line in two places (`Claude.lua:149` and the string branch at
`151-153`) and `Agent.lua:432-453` already prints the two numbers that settle
it. Not changed, because it contradicts a documented decision.

**`run` is offered even while disabled.** `Settings.allowRun` defaults false
and the guard is in `Terminal:run` (`Terminal.lua:704`), but `buildTools()`
offers the tool every turn, so each attempt is a wasted turn. Filtering it out
is not a clean win though: the error it returns — *"enable it in Settings > Run
code"* — is the only thing that ever tells the user the capability exists, and
`isSeparateTool` asks the registry, so `bash` would still claim *"run is a
separate tool"* for a tool no longer offered. A trade, not a saving.

**Two comments describe behaviour the code lacks.** `tools/bash.lua:3-6` says
the description *"carries the MAPPING … that this filesystem is a DataModel"* —
it does not; the description never mentions it. And `Terminal.lua:715-717`
justifies having no timeout with *"The tool description tells Claude to bound
its loops"* — `tools/run.lua:7` states the hazard but never gives the
instruction. The second is worth ~10 tokens to fix regardless, since the
failure mode is Studio freezing. The first may cost nothing: a bare `ls` at
root returns `Workspace`, `Players`, `Lighting`, which may be signal enough.

**`write` and `bash`'s `>` are one operation behind two doors.**
`applyRedirect` (`Shell.lua:367`) calls the same `Terminal:write` the `write`
tool calls, and nothing tells the model which to prefer. `edit.lua:3-5` already
knows the answer — shell quoting eventually corrupts source — it just never
says it anywhere the model reads. Remove neither: `>` is what lets pipelines
terminate, `write` is what keeps Luau source out of the tokenizer.

Also considered and rejected: merging `edit` into `multiedit`. `Terminal:edit`
is already `multiedit(path, {one})` (`Terminal.lua:530`) so there is no
duplicated logic to remove, only ~267 chars of schema — and forcing every
single-hunk edit to carry an `edits` array walks straight into the failure
`Agent.lua:27-40` documents, where a long `edits` payload truncated by
`max_tokens` arrives as invalid JSON and poisons the history.

## Checks

`Agent.selfTest()` (`Agent.lua:662`), wired into `main.lua` alongside the
Markdown, Terminal and Props self-tests. Covers the truncation shape, the UTF-8
boundary, the line-boundary cut, and every rule in §7 — pairing preserved, no
empty content, recent results untouched, idempotent, and a small history left
alone. Fixture sizes derive from `MODEL_RESULT_CHARS` rather than being written
as literals, so raising the cap cannot silently stop the tests exercising
anything.
