-- Agent.luau: the conversation and the streaming tool-use loop.
--
-- This replaces the old sendToClaude / sendToClaude_continue pair. Those were
-- ~90% identical, and the drift between them was a real bug: the continue path
-- omitted onToolUseStart, which used to gate tool-input parsing, so every
-- follow-up turn sent `input: []` and Anthropic rejected it. One function means
-- one code path to keep correct.

local ui = script.Parent.Parent:WaitForChild("ui")

-- Only to measure the tool schemas for the settings panel's context breakdown:
-- their punctuation is most of their token cost, so the encoded form is the
-- honest size and a recursive string-sum is not. Nothing here sends a request.
local HttpService = game:GetService("HttpService")

local Provider = require(script.Parent:WaitForChild("Provider"))
local Tools = require(script.Parent:WaitForChild("Tools"))
local Console = require(ui:WaitForChild("Console"))
local Settings = require(ui:WaitForChild("Settings"))
-- Only for the editor-context line on each user message: which scripts are open
-- and where the cursor is.
local Fs = require(script.Parent.Parent:WaitForChild("fs"):WaitForChild("Fs"))

local Agent = {}

-- There is deliberately NO cap on the tool-use loop, which is what Claude Code
-- does: `maxTurns` (src/query.ts) is optional and left unset in its interactive
-- path, enforced only for `--max-turns`, the SDK and subagents. A turn count of
-- 40 was stopping real work mid-refactor, and the thing it was guarding against
-- is already covered, the loop only continues while the model asks for more
-- tools, Stop and Escape both cancel, and clearOldToolResults keeps the history
-- from growing without bound. runTurn recurses through task.spawn, so depth
-- costs no stack either. `turn` survives as the depth, which the rollback paths
-- below still need to tell the first turn from the rest.

-- Blocks Anthropic executes and returns complete, replayed as-is.
--
-- Matched on the `_tool_result` suffix rather than a list of names. The list was
-- the bug: it held web_search, web_fetch and the legacy bare code_execution, so
-- a `text_editor_code_execution_tool_result` fell through and was dropped while
-- its server_tool_use was kept, and the next request died with "tool use ... was
-- found without a corresponding ... block". Every later turn failed the same
-- way, because the unanswered call is in the history for good.
--
-- An allowlist fails unsafely here: anything Anthropic adds, or runs on its own
-- (web_search_20260209 does code execution under the hood for result filtering),
-- silently poisons the session instead of erroring where the loss happens. The
-- suffix covers bash_, text_editor_, mcp_, tool_search_ and whatever comes next.
--
-- Safe because thinking, redacted_thinking, text, tool_use and server_tool_use
-- all match earlier branches, so nothing whose `raw` is the empty shell from
-- content_block_start can reach here.
local function isServerResult(blockType: string?): boolean
	return type(blockType) == "string" and blockType:sub(-12) == "_tool_result"
end

-- tool_use.input must be a JSON *object* on the wire, and Roblox's encoder turns
-- an empty Lua table into `[]`. That rejection is not a one-turn failure: the
-- block is already in the history, so every later request fails on the same
-- index: "messages.27.content.1.tool_use.input: Input should be an object"
-- until the conversation is cleared. It fires whenever the accumulated input
-- JSON does not parse, which fine-grained tool streaming makes possible: an
-- input cut short by max_tokens arrives as invalid JSON rather than being
-- buffered and validated. `edits` payloads are the longest thing the model
-- sends, so multiedit is where it shows up.
--
-- Roblox has no object sentinel, so the fallback carries the raw fragment
-- instead of nothing: an object either way, and it shows what was cut off. This
-- is what Anthropic's own guidance says to do: "if you need to pass invalid
-- JSON back to the model in an error response block, you may wrap it in a JSON
-- object ... with a reasonable key", so a truncated call costs one corrective
-- turn and nothing else. The other half of the recovery is the stop_reason in
-- the error text below, which is what tells the model to send LESS rather than
-- resend the same payload. Nothing further is worth building here; the lever
-- that actually reduces how often it happens is max_tokens, which Settings ties
-- to the effort level.
-- Capped because a truncated multiedit can be thousands of characters and this
-- stays in the history for the rest of the session.
local function toolInput(block: any): any
	local parsed = block.inputParsed
	if type(parsed) == "table" and next(parsed) ~= nil then
		return parsed
	end
	return { _unparsed = string.sub(tostring(block.input or ""), 1, 200) }
end

-- What a tool result costs
-- A tool result goes into `conversation` and stays there for the rest of the
-- session, re-read on every later turn. `Shell.run` returns whatever the
-- command produced with no ceiling, so one `cat` of a large ModuleScript or one
-- `ls -R /` is tens of thousands of tokens paid over and over, the only thing
-- here that can blow up on a SINGLE call.
--
-- Claude Code splits this in two: shell output is capped at 30 000 characters,
-- but a file READ gets 25 000 tokens, because reading a file whole is a primary
-- operation while shell output is usually incidental. 100 000 characters is
-- that read budget at the four-characters-per-token rule the same codebase
-- estimates with.
--
-- We take the larger number for everything, because the split is not available
-- here: `cat` is not a separate tool, it arrives as a `bash` line, and telling a
-- read from a listing would mean parsing the command in Agent, where
-- `cat x | grep y` has no honest answer anyway. The cost of one number is a
-- worse worst case for `ls -R /`, which can now spend 100 000 characters
-- instead of 30 000. Accepted: that is a ceiling only pathological output
-- reaches, typical listings are a few hundred characters, and clearOldToolResults
-- below reclaims it once the result is stale. The cost of the SMALLER number was
-- truncating `cat` of a ~1000-line script, which is an ordinary thing to do.
--
-- Head rather than tail because shell output front-loads: the top of an `ls` or
-- a `cat` is the part that answers the question.
--
-- The Console already has the whole string by the time this runs, so the user
-- still sees everything, only the copy going on the wire is cut.
local MODEL_RESULT_CHARS = 100000

-- Cutting a byte string at a fixed offset can land mid-codepoint, and
-- JSONEncode rejects invalid UTF-8, a truncation that kills the request is
-- worse than no truncation at all. A newline is always a codepoint boundary and
-- a tidier place to stop, so prefer the last one; fall back to stepping off
-- continuation bytes (0x80-0xBF) when there is no newline to find, which is the
-- one-enormous-line case.
local function safeCut(s: string, limit: number): string
	local head = string.sub(s, 1, limit)
	-- Greedy `.*` backtracks to the last newline; `()` captures just past it.
	-- Ignored when it would throw away most of the budget, which happens when a
	-- short first line is followed by one very long one.
	local afterNewline = string.match(head, "^.*\n()")
	if afterNewline and afterNewline > limit / 2 then
		return string.sub(s, 1, afterNewline - 1)
	end
	local n = limit
	-- A codepoint is at most 4 bytes, so this steps back at most 3 times.
	for _ = 1, 3 do
		local nextByte = string.byte(s, n + 1)
		if nextByte == nil or nextByte < 0x80 or nextByte > 0xBF then break end
		n -= 1
	end
	return string.sub(s, 1, n)
end

-- Naming the narrower commands is the load-bearing half. Without it the model's
-- next move is to re-run the same unbounded command and pay for it twice.
local function forModel(result: string, limit: number?): string
	local cap = limit or MODEL_RESULT_CHARS
	if #result <= cap then return result end
	local kept = safeCut(result, cap)
	return string.format(
		"%s\n... [%d characters truncated] ...\n" ..
		"Re-run narrowed to see the rest: `head -n`, `tail -n`, `sed -n '10,40p'`, " ..
		"or `grep` for what you are actually looking for.",
		kept, #result - #kept)
end

-- One turn's tool_results all travel in ONE user message, so a per-result cap
-- is not the whole story. Parallel tool use is on and is the largest lever in
-- this file, which makes it also the largest way to blow the window: six calls
-- that each stop just under MODEL_RESULT_CHARS put 600 000 characters into a
-- single message, and once that pair is in the history it is there for good.
--
-- Claude Code caps the same thing at the same number
-- (MAX_TOOL_RESULTS_PER_MESSAGE_CHARS = 200 000, also per user message, also
-- evaluated per message rather than cumulatively). The SELECTION is not the
-- same and should not be copied: selectFreshToReplace sorts largest-first and
-- spills whole results to a file until the message is under budget, leaving the
-- others untouched. That only works because the bytes survive on disk. A plugin
-- has nowhere to spill, so blanking a whole result would destroy it outright;
-- every result is shaved instead.
--
-- Smallest-first fair share: every result already under its share releases the
-- remainder to the ones over it. A turn of three short listings and one huge
-- `tree` therefore spends nearly the whole budget on the tree instead of
-- quartering it. At 2x the per-result cap this only binds from the third large
-- result onward, so the ordinary ls+cat+grep sweep never notices it.
local MODEL_TURN_CHARS = 2 * MODEL_RESULT_CHARS

local function capTurn(results: { any })
	-- Shallow: the entries are the same tables, so assigning content mutates
	-- the blocks that are about to go on the wire.
	local order = table.clone(results)
	table.sort(order, function(a, b)
		return #a.content < #b.content
	end)

	local budget = MODEL_TURN_CHARS
	for index, entry in ipairs(order) do
		local share = math.min(MODEL_RESULT_CHARS, budget // (#order - index + 1))
		entry.content = forModel(entry.content, share)
		budget -= #entry.content
	end
end

-- A web_search_tool_result's content is either the list of hits or a single
-- error object. Each hit also carries `encrypted_content`, a multi-KB opaque
-- blob that exists only so the result can be replayed on the next turn, it is
-- deliberately not shown, or the details panel would be a wall of base64.
local function formatServerResult(content: any): string
	if type(content) ~= "table" then return tostring(content) end
	if content.type == "web_search_tool_result_error" then
		return "error: " .. tostring(content.error_code)
	end
	local lines: { string } = {}
	for i, hit in ipairs(content) do
		table.insert(lines, string.format("%d. %s", i, tostring(hit.title or "(untitled)")))
		if hit.url then table.insert(lines, "   " .. tostring(hit.url)) end
	end
	if #lines == 0 then return "(no results)" end
	table.insert(lines, 1, string.format("%d results", #content))
	return table.concat(lines, "\n")
end

-- Our registered tools, plus Anthropic's server-side web search when the user
-- has turned it on. Server tools need no dispatcher: the API runs them.
--
-- Tools.definitions() builds fresh tables every call, which is what makes it
-- safe for streamMessage to tag the last entry with cache_control. When this
-- read from a shared literal, that tag stayed on the definition for the rest of
-- the session, turn web search on afterwards and the stale breakpoint was still
-- sitting on `catalog` while a fresh one went on web_search. Anthropic caps a
-- request at 4 cache_control blocks across system + tools + messages, so two in
-- tools leaves no headroom and the next one added fails the whole request.
--
-- Tool ORDER is load-bearing and must not vary between turns: definitions render
-- ahead of everything else in the request, and caching is a prefix match, so a
-- reorder invalidates the system and conversation breakpoints too. The registry
-- sorts; web search is appended last so toggling it only ever invalidates from
-- the end of the tool block onward.
-- Switched-off tools are removed HERE rather than refused at dispatch, and the
-- trade is deliberate. Removing changes the tool block, so flipping a toggle
-- costs one cache re-write from the tool block onward — paid once, while the
-- reader is already in the settings panel. Leaving them in and refusing the call
-- instead costs a wasted tool call every turn the model reaches for something it
-- is never allowed to have, forever. Tools.dispatch refuses too, but as a
-- backstop for a call replayed out of old history, not as the mechanism.
--
-- Relative order is preserved, so the surviving prefix is still stable turn to
-- turn; only the one change invalidates.
local function buildTools(): { any }
	local out: { any } = {}
	for _, def in ipairs(Tools.definitions()) do
		if Settings.toolEnabled(def.name) then
			out[#out + 1] = def
		end
	end
	return out
end

local term: any = nil
local conversation: { any } = {}
local busy = false
local onBusyChanged: ((boolean) -> ())? = nil
-- Fired where the conversation is complete and valid but the run is nowhere
-- near idle: as the user's message goes in, and after each batch of tool
-- results. The session used to be written to disk on the busy -> idle edge and
-- NOWHERE else, and a long run is a single busy period — a place that crashed
-- twenty tool calls into one lost every one of them and reopened from before
-- the message that started it. The edge still saves; this is the same save, at
-- each step of the way there.
--
-- A callback rather than requiring Sessions, which requires Agent — the entry
-- point owns that wiring, as it does for onBusyChanged.
local onCheckpoint: (() -> ())? = nil
-- Set while a turn is in flight; cleared the moment it settles. Agent.stop()
-- calls this, which is what the Stop button drives.
local stopCurrent: (() -> ())? = nil
-- Running total for this session, the equivalent of the Session block in Claude
-- Code's /usage. Plan limits are a separate thing and come from the usage
-- endpoint (Auth.fetchUsage); this is just what this session has spent.
--
-- `cached` is the read half of `input`, not a third number beside it: input is
-- fresh + read + written, so cached/input is the hit rate over the session. A
-- turn's own split is printed under it by the per-turn line below; this is the
-- one that says whether the cache is working at all, which is the question a
-- long run actually has.
--
-- `prompt` is not a total: it is the LAST request's whole input — fresh + read +
-- written — which is how much of the context window this conversation currently
-- occupies. A running sum answers a different question (what the session spent)
-- and would climb past the window on turn three while the window sat half empty.
-- Zero before the first reply, where there is nothing measured to show.
local totals = { input = 0, output = 0, cached = 0, cacheWrite = 0, prompt = 0, requests = 0 }

-- Wall clock over the same span `totals` covers, which is the plugin's lifetime
-- and not the conversation's: Agent.reset clears the window measurement and
-- deliberately leaves what was SPENT alone, so a duration that restarted on
-- /clear would disagree with every other number beside it.
local sessionStartedAt = os.clock()
-- tool_use / server_tool_use id -> the console block waiting for its result.
-- Keyed by id rather than "the last one", because a turn can run several calls
-- and parallel tool use means their blocks are all open at once.
--
-- Deliberately NOT per-turn. On stop_reason "pause_turn" Anthropic interrupts a
-- long-running search, so the server_tool_use lands in one stream and its
-- web_search_tool_result in the NEXT one, after runTurn has recursed. A per-turn
-- table lost the pairing across that boundary: the first block spun forever and
-- the result arrived as a second, argument-less [web_search] below it. Parallel
-- searches hit it most, being the slowest turns and the likeliest to be paused.
local pendingCalls: { [string]: any } = {}

-- os.time() of the last request. nil means none has gone out, so there is no
-- cached prefix to protect, a restored session starts here too, since its
-- prefix was last written by whichever session saved it.
--
-- Declared HERE, with the rest of the session state, and not down beside
-- cacheIsCold where it reads more naturally. Agent.restore clears it, and
-- restore is defined above that point: a local declared after its own
-- assignment is not that local at all, it is a global, so the clear silently
-- did nothing and a restored session was treated as cache-warm.
local lastRequestAt: number? = nil

function Agent.Initialize(terminal: any, busyCallback: ((boolean) -> ())?,
	checkpointCallback: (() -> ())?)
	term = terminal
	onBusyChanged = busyCallback
	onCheckpoint = checkpointCallback
end

function Agent.conversation(): { any }
	return conversation
end

function Agent.reset()
	conversation = {}
	-- The window is empty again, so the last measurement no longer describes it.
	-- input/output/cached are deliberately left alone: those are what this session
	-- has SPENT, and clearing the history does not un-spend it.
	totals.prompt = 0
end

-- Adopts a saved conversation wholesale (Sessions). Takes the table rather than
-- copying it, so later turns append to the same list the caller holds.
function Agent.restore(messages: { any })
	conversation = messages
	-- This prefix was last written by whatever session saved it, so nothing here
	-- is cached under the current one. Clearing the stamp says so, which makes
	-- the first turn after a restore the free one to clear on.
	lastRequestAt = nil
	-- Nothing has measured THIS history yet. The restored messages have a real
	-- size, but only the next reply's usage can report it, and carrying the
	-- previous conversation's number over would describe the wrong one.
	totals.prompt = 0
end

function Agent.usage(): {
	input: number, output: number, cached: number, cacheWrite: number,
	prompt: number, requests: number,
}
	return totals
end

-- Seconds since the plugin loaded. Wall, not API time: timing the requests
-- themselves would mean threading a clock through Stream, and the number a
-- reader wants from a session summary is how long they have been at it.
function Agent.sessionElapsed(): number
	return os.clock() - sessionStartedAt
end

function Agent.isBusy(): boolean
	return busy
end

local function setBusy(value: boolean)
	busy = value
	if not value then
		-- Nothing appended after a turn belongs to its message.
		Console.setMessage(0)
		stopCurrent = nil
		-- The request is over, so anything still waiting on a result is never
		-- getting one, a cancel or an error mid-search. Stop the spinners rather
		-- than leave them turning until the widget closes.
		for id, call in pairs(pendingCalls) do
			call.finish()
			pendingCalls[id] = nil
		end
	end
	if onBusyChanged then onBusyChanged(value) end
end

-- Cancels the in-flight turn. Safe to call when idle.
function Agent.stop()
	local stop = stopCurrent
	if stop then stop() end
end

-- Keeping the history bounded
-- forModel() caps any single result and capTurn() caps one turn's batch of
-- them; nothing caps the sum across turns. `conversation` is append-only, so a
-- long session ends by hitting the context window and dying with no way back
-- from it. This is Claude Code's microcompact minus the half we cannot have:
-- upstream a result that is too LARGE is spilled to disk and replaced by a
-- <persisted-output> pointer first, so the bytes still exist in a file when the
-- age-based clear later overwrites that pointer. A plugin has nowhere to spill
-- to, so what is cleared here is gone outright.
--
-- Two things this has to get right, or it makes matters worse than it found
-- them:
--
--   Stub the content, never remove the block. Every tool_result pairs with a
--   tool_use already in the history; drop one and every later request fails on
--   the same index for the rest of the session. Empty content is rejected
--   outright (see the "(no output)" guard below), so the stub is a non-empty
--   sentence: kept short, because it is paid once per cleared result and
--   because anything it replaces has to be LONGER than it or clearing costs
--   tokens instead of saving them. Claude Code's string verbatim
--   (TIME_BASED_MC_CLEARED_MESSAGE in microCompact.ts), which is about as short
--   as saying what happened gets. Neither theirs nor ours names a recovery:
--   their stub overwrites the persisted-output pointer too, so on both sides a
--   cleared result is gone from context.
--
--   Run it only when the prefix is being re-written anyway. Mutating a message
--   invalidates the cache from that index onward, and old results sit near the
--   FRONT of the history, so a pass re-writes almost the entire prefix at the 1h
--   write rate. Size it: at 50k tokens of history, clearing 20k costs 2.0x30k
--   now against 0.1x50k for the read it replaced, and returns 0.1x20k per later
--   turn: about 28 turns to break even, on a session that will re-cross the
--   trigger long before that. The saving scales with what is cleared; the cost
--   scales with the whole prefix, so no saving threshold can make a warm-cache
--   pass pay for itself. Hence cacheIsCold() below.
-- ponytail: tool results only. A session that grows on assistant text rather
-- than tool output, or one with five results and nothing older, is still
-- unbounded, because there is nothing here for this to clear. Upgrade path is
-- summarising compaction, which replaces spans of history with a paragraph
-- instead of only blanking results.
local KEEP_RECENT = 5
local CLEARED = "[Old tool result content cleared]"
local TRIGGER_CHARS = 200000    -- ~50k tokens of history before this is worth looking at
local MIN_SAVING_CHARS = 80000  -- ~20k tokens; below this even a paid-for re-write is not worth it
local URGENT_BUFFER_TOKENS = 13000 -- headroom left below the window; theirs, AUTOCOMPACT_BUFFER_TOKENS
local COLD_AFTER = 60 * 60      -- seconds; the full 1h TTL withMessageCache asks for, not a hair under

-- Past COLD_AFTER the 1h TTL has expired, the whole prefix is re-written on the
-- next request whatever we do, and clearing first only shrinks what gets
-- re-written, so the pass is free. This is Claude Code's time-based
-- microcompact trigger (evaluateTimeBasedTrigger); it is the one part of that
-- mechanism a plugin can have, since the TTL we asked for is knowable
-- client-side while their other two free paths are not (cache_edits needs a
-- server-side context_management API, autocompact needs somewhere to spill).
--
-- The full hour, not a hair under. Their comment gives the rule: 60 minutes is
-- "the safe choice: the server's 1h cache TTL is guaranteed expired for all
-- users, so we never force a miss that wouldn't have happened." Anything short
-- of the TTL can still land on a live cache, which is the exact miss this gate
-- exists to avoid, erring early here does the damage it is meant to prevent,
-- while erring late costs one turn of carrying results that were free to carry.
--
-- Wall clock rather than a monotonic one, because the gap being measured is the
-- user leaving the widget docked, not CPU time. A clock stepped backwards reads
-- as warm and skips a pass; forwards, it buys one unnecessary re-write. Neither
-- is worth guarding.
local function cacheIsCold(): boolean
	return lastRequestAt == nil or os.time() - lastRequestAt >= COLD_AFTER
end

-- Whether the next request should still find its prefix in the server's cache.
--
-- A PREDICTION, not a fact, and the difference is the whole reason this is
-- documented rather than just exported. It says only that the 1h TTL we ask for
-- has not run out since the last request — which is the right clock, because a
-- cache READ refreshes the entry's timer at no cost, so every turn pushes
-- expiry an hour out. It cannot see a prefix CHANGE: a different model, an
-- edited system prompt, a cleared tool result all miss on a timer that says
-- warm. So true means "not expired", never "guaranteed hit".
--
-- The fact is only ever available afterwards, as usage.cache_read_input_tokens
-- on the reply. That is the number the Cache hits row reports; this one is for
-- the panel to say what the NEXT turn is walking into.
--
-- Defined here rather than up with the other accessors on purpose: cacheIsCold
-- is a local, and a function written above it would capture the global of that
-- name — nil — instead. Same trap as lastRequestAt's own declaration note.
function Agent.cacheWarm(): boolean
	return not cacheIsCold()
end

-- A tool_use input is a TABLE, so it cannot be measured with `#` like the rest.
-- Summing its strings rather than JSONEncoding it keeps this allocation-free:
-- historyChars walks the entire conversation every turn, and encoding every
-- `write` payload each time to measure it would cost more than the threshold
-- saves. Undercounts keys, braces and quoting, which is the right direction for
-- a trigger whose action costs a cache re-write.
local function inputChars(value: any, depth: number): number
	if type(value) == "string" then return #value end
	-- multiedit nests one level (an array of {old, new}); the bound is here so a
	-- malformed input cannot walk forever.
	if type(value) ~= "table" or depth > 4 then return 0 end
	local total = 0
	for _, inner in pairs(value) do
		total += inputChars(inner, depth + 1)
	end
	return total
end

-- Deliberately an estimate, not a token count: it only decides whether to look
-- closer.
--
-- tool_use inputs USED to go uncounted, which mattered more than it looked:
-- `write` and `multiedit` carry their whole payload there, nothing ever clears a
-- tool_use, and the urgent gate is the only backstop against a history that will
-- not fit. It was the largest object in the conversation and scored zero. That
-- was survivable while max_tokens scaled with effort and capped a single write
-- at ~8k tokens; it is not now that the ceiling is the model's real 128k.
--
-- Counting them reclaims nothing by itself and changes no clearing behaviour —
-- clearing still touches results only, deliberately, since a write's input is
-- the record of what changed. It makes the threshold measure what it guards.
-- The same walk, split by what the characters ARE. historyChars sums it, so
-- there is one traversal of the conversation and not two that can disagree.
--
-- Order is the display order, and it is fixed rather than sorted by size: a
-- panel whose rows reshuffle between two openings is one nobody can read a
-- trend off. `key` is what the walk writes into; `label` is what the panel shows.
local HISTORY_BUCKETS = {
	{ key = "user", label = "Your messages" },
	{ key = "assistant", label = "Assistant" },
	{ key = "toolCalls", label = "Tool calls" },
	{ key = "toolResults", label = "Tool results" },
}

local function historyBuckets(messages: { any }): { [string]: number }
	local out = { user = 0, assistant = 0, toolCalls = 0, toolResults = 0 }
	for _, message in ipairs(messages) do
		local content = message.content
		local mine = if message.role == "user" then "user" else "assistant"
		if type(content) == "string" then
			out[mine] += #content
		elseif type(content) == "table" then
			for _, block in ipairs(content) do
				if type(block) == "table" then
					-- A tool_result's payload and a text block's text are both strings
					-- on the block, so the TYPE is what tells them apart. Read off
					-- block.type rather than the message role: a tool_result rides in
					-- a user message, and counting it as something the user typed is
					-- how the largest bucket in an agent session hides in the smallest.
					if block.type == "tool_result" then
						if type(block.content) == "string" then
							out.toolResults += #block.content
						end
					elseif block.type == "tool_use" then
						if block.input ~= nil then
							out.toolCalls += inputChars(block.input, 0)
						end
					else
						-- text and thinking. Both belong to whoever's message they are in.
						if type(block.text) == "string" then out[mine] += #block.text end
						if type(block.content) == "string" then out[mine] += #block.content end
						if block.input ~= nil then out[mine] += inputChars(block.input, 0) end
					end
				end
			end
		end
	end
	return out
end

local function historyChars(messages: { any }): number
	local buckets = historyBuckets(messages)
	local total = 0
	for _, value in pairs(buckets) do
		total += value
	end
	return total
end

-- Where the context window actually went, as { label, tokens } in a fixed order.
--
-- There is NO endpoint that returns this. `usage` on a reply gives the total and
-- its cache split (and, under `usage.cache_creation`, a per-TTL breakdown of the
-- writes) — never a breakdown by what the tokens were. Claude Code gets the
-- split by calling POST /v1/messages/count_tokens once PER CATEGORY, in parallel,
-- with a Haiku count as the fallback (analyzeContext.ts, countTokensWithFallback)
-- — an HTTP round trip per row of the display, every time /context is typed.
--
-- This does not, because it does not have to. Two facts do the work:
--
--   1. the EXACT total is already known and cost nothing — it is what the last
--      reply billed, fresh + read + written (see totals.prompt);
--   2. the categories only have to be RIGHT RELATIVE TO EACH OTHER, because
--      they are then scaled to sum to that exact total.
--
-- So the bytes-per-token constants below never need to be accurate. Scaling
-- cancels any uniform error in them exactly, which is why this can be a local
-- character count and still put a true number on every row. What the constants
-- have to get right is the RATIO between prose and dense JSON: a tool schema or
-- a `write` payload spends a token roughly every 2 bytes, where prose takes
-- about 4, and one constant for both reads a page of schemas as half its real
-- share. Claude Code carries the same two numbers for the same reason
-- (bytesPerTokenForFileType).
--
-- Before the first reply there is no measurement to scale to, and the second
-- return says so. This used to answer nil there, on the grounds that an unscaled
-- estimate is an estimate wearing a measurement's clothes — but the clothes were
-- the problem, not the estimate. A restored session is exactly when "how full am
-- I before I send" is worth asking, and the constants are a rule of thumb good to
-- roughly a fifth, which answers it. The caller marks it approximate.
local BYTES_PER_TOKEN_TEXT = 4
local BYTES_PER_TOKEN_JSON = 2

export type ContextRow = { label: string, tokens: number }

-- Returns the rows and whether they are MEASURED. Measured means scaled to what
-- the last reply actually billed, so the rows sum to a true total; unmeasured
-- means the raw character estimate, which is only ever the pre-first-reply case.
function Agent.contextBreakdown(): ({ ContextRow }?, boolean)

	-- The system prompt and the tool schemas are the part a walk of `conversation`
	-- cannot see, and on a fresh session they ARE the context: several thousand
	-- tokens before anything is typed. Left out, every other row is overstated by
	-- exactly their share, and the panel says a one-message session is 40% full of
	-- "Your messages".
	local rows: { ContextRow } = {}
	local weighted: { number } = {}
	local function add(label: string, chars: number, bytesPerToken: number)
		if chars <= 0 then return end
		rows[#rows + 1] = { label = label, tokens = 0 }
		-- +1, and the bug this fixes is why the breakdown never once appeared:
		-- `weighted[#weighted]` writes index 0 on an empty table, and index 0 does
		-- not count toward `#`, so every later call overwrote the same slot and the
		-- table stayed empty as far as ipairs was concerned. estimate summed to 0,
		-- the guard below read that as "nothing to show", and contextBreakdown
		-- returned nil on every call it has ever received. Indexes here line up
		-- with `rows`, so this must append exactly as rows[#rows + 1] does.
		weighted[#weighted + 1] = chars / bytesPerToken
	end

	add("System prompt", #(Settings.system() or ""), BYTES_PER_TOKEN_TEXT)
	-- The schemas as they go on the wire. JSONEncode rather than summing the
	-- strings: the punctuation is most of a schema and most of its token cost,
	-- and it is exactly what a recursive string-sum would leave out.
	local encoded = ""
	pcall(function()
		encoded = HttpService:JSONEncode(buildTools())
	end)
	add("Tool schemas", #encoded, BYTES_PER_TOKEN_JSON)

	local buckets = historyBuckets(conversation)
	for _, bucket in ipairs(HISTORY_BUCKETS) do
		-- Tool calls carry a `write`'s whole payload as JSON; the rest is prose.
		add(bucket.label, buckets[bucket.key],
			if bucket.key == "toolCalls" then BYTES_PER_TOKEN_JSON else BYTES_PER_TOKEN_TEXT)
	end

	local estimate = 0
	for _, value in ipairs(weighted) do
		estimate += value
	end
	if estimate <= 0 then
		return nil, false
	end
	-- The one line that makes the rest exact in aggregate — when there is
	-- something to be exact against. A scale of 1 leaves the raw estimate, which
	-- is the honest answer before the first reply rather than no answer.
	local measured = totals.prompt > 0
	local scale = if measured then totals.prompt / estimate else 1
	for index, row in ipairs(rows) do
		row.tokens = math.floor(weighted[index] * scale)
	end
	return rows, measured
end

-- The point past which the window, not the cache, is the risk, in the same
-- character unit as historyChars so the caller compares one number.
--
-- Sized off the model, which is the whole reason this is a function rather than
-- the constant it used to be: a fixed 600 000 characters (~150k tokens) was
-- wrong at both ends of the range it has to cover, firing at 15% full on a
-- 1M-token model and never before the window itself on a 200k one. Claude Code
-- sizes the same gate the same way, getEffectiveContextWindowSize(model) minus
-- AUTOCOMPACT_BUFFER_TOKENS.
--
-- nil when the provider cannot name the window (OpenRouter returns number? for
-- a model it has never heard of). There is then no urgent line at all and only
-- the cold path clears, which is the conservative direction: a warm pass costs
-- a full prefix re-write, and inventing a window to justify one would spend
-- real tokens on a guess.
--
-- The estimate leaves out the system prompt and the tool schemas, which
-- historyChars does not walk. A few hundred tokens against 13 000 of headroom.
local function urgentChars(): number?
	local wire = Provider.wire
	if not (wire and wire.contextWindow) then return nil end
	local window = wire.contextWindow(Settings.model())
	if not window then return nil end
	return (window - URGENT_BUFFER_TOKENS) * BYTES_PER_TOKEN_TEXT
end

-- Returns the number of characters dropped; 0 means nothing was touched and the
-- cache is intact.
local function clearOldToolResults(messages: { any }): number
	local chars = historyChars(messages)
	if chars < TRIGGER_CHARS then return 0 end

	-- Cheap enough to re-check every turn, and it has to be: the same history
	-- that is not worth clearing during an active sweep becomes worth clearing
	-- the moment the user walks away from it.
	local cold = cacheIsCold()
	-- Warm and merely large: leave it. The one exception is a history close
	-- enough to the window that the next few turns could fail outright, there
	-- the re-write is the cheaper of two bad options, because nothing else here
	-- reclaims anything.
	local urgent = urgentChars()
	if not cold and (urgent == nil or chars < urgent) then return 0 end

	local results: { any } = {}
	for _, message in ipairs(messages) do
		local content = message.content
		if type(content) == "table" then
			for _, block in ipairs(content) do
				if type(block) == "table" and block.type == "tool_result" then
					table.insert(results, block)
				end
			end
		end
	end

	-- Counted over every result, cleared ones included, so "the last five" means
	-- the same five however many passes have run.
	local cutoff = #results - KEEP_RECENT
	if cutoff <= 0 then return 0 end

	-- A result at or below the stub's length would GROW if replaced. Not a
	-- hypothetical: the "" guard turns silent commands into "(no output)", which
	-- is 11 characters, and `echo`, `diff` of identical scripts and anything
	-- redirected to /dev/null all produce one.
	local function worthClearing(block: any): boolean
		return type(block.content) == "string" and #block.content > #CLEARED
	end

	local saving = 0
	for i = 1, cutoff do
		if worthClearing(results[i]) then
			saving += #results[i].content - #CLEARED
		end
	end
	-- A free pass only has to beat zero, which is Claude Code's guard in this
	-- exact position (`if (tokensSaved === 0) return null`, there is no saving
	-- floor upstream). MIN_SAVING_CHARS applies to the urgent path only, where
	-- the re-write is actually being paid for.
	if saving < (if cold then 1 else MIN_SAVING_CHARS) then return 0 end

	for i = 1, cutoff do
		if worthClearing(results[i]) then
			results[i].content = CLEARED
		end
	end
	return saving
end

-- Token budget
-- Claude Code's src/query/tokenBudget.ts, ported. A model that stops at 40% of a
-- task it had room to finish is the failure this catches: when a turn ends
-- naturally under the target, the stop is not accepted — the model is told how
-- much it has left and asked to carry on.
--
-- The budget comes out of the READER'S OWN MESSAGE, which is what makes it safe
-- to have on by default. `+500k` or "use 2m tokens" arms it for that request;
-- type neither and there is no budget and none of this runs. Upstream gates it
-- the same way (`budget === null` -> stop) rather than behind a setting, and it
-- is the better design: per-message, inert unless asked for, nothing to
-- misconfigure once and regret for a session.
--
-- "do not summarize" in the message below is load-bearing and is upstream's
-- wording. Without it the answer to "keep working" is a report about the work
-- already done, which spends the budget saying nothing new.
local COMPLETION_THRESHOLD = 0.9
local DIMINISHING_THRESHOLD = 500  -- tokens; two quiet rounds in a row means done
local BUDGET_SCALE: { [string]: number } = { k = 1000, m = 1000000, b = 1000000000 }

local budget: number? = nil        -- nil for every request that did not ask
local budgetSpent = 0              -- output tokens since the reader's message
local continuations = 0
local lastDelta = 0
local lastChecked = 0

-- Anchored at the start or the end for the shorthand, deliberately: "+2k" in
-- the middle of a sentence about a diff is prose, not a budget. The verbose form
-- names tokens outright, so it can match anywhere.
local function parseTokenBudget(text: string): number?
	local lower = string.lower(text)
	local function scaled(n: string, suffix: string): number?
		local value, mult = tonumber(n), BUDGET_SCALE[suffix]
		return if value and mult then value * mult else nil
	end
	local n, suffix = lower:match("^%s*%+(%d+%.?%d*)%s*([kmb])%f[%W]")
	if n then return scaled(n, suffix) end
	n, suffix = lower:match("%s%+(%d+%.?%d*)%s*([kmb])%s*[.!?]?%s*$")
	if n then return scaled(n, suffix) end
	for _, verb in ipairs({ "use", "spend" }) do
		n, suffix = lower:match("%f[%a]" .. verb .. "%s+(%d+%.?%d*)%s*([kmb])%s*tokens?%f[%W]")
		if n then return scaled(n, suffix) end
	end
	return nil
end

local function withCommas(n: number): string
	local out = tostring(math.floor(n))
	local more = 1
	while more > 0 do
		out, more = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
	end
	return out
end

-- The nudge for a turn that stopped early, or nil to let it stop.
--
-- Two ways to be finished. Spending the target is the obvious one. The other is
-- diminishing returns: three rounds in, answering a nudge with almost nothing
-- twice running means the model is out of work, not out of budget, and nudging
-- a fourth time buys a paragraph of throat-clearing. Both of upstream's
-- thresholds, unchanged.
--
-- A missing `usage` is safe rather than a hang: budgetSpent stops growing, the
-- deltas are 0, and the diminishing branch ends the turn after three rounds.
local function budgetContinuation(): string?
	if not budget or budget <= 0 then return nil end
	local target = budget :: number
	local delta = budgetSpent - lastChecked
	local diminishing = continuations >= 3
		and delta < DIMINISHING_THRESHOLD
		and lastDelta < DIMINISHING_THRESHOLD
	if diminishing or budgetSpent >= target * COMPLETION_THRESHOLD then
		return nil
	end
	continuations += 1
	lastDelta = delta
	lastChecked = budgetSpent
	return string.format(
		"Stopped at %d%% of token target (%s / %s). Keep working — do not summarize.",
		math.floor(budgetSpent / target * 100 + 0.5), withCommas(budgetSpent), withCommas(target))
end

-- One turn
-- Streams a response, renders it, runs any tools it asked for, and recurses if
-- Claude wants another round. `turn` is the recursion depth.
local function runTurn(turn: number)
	-- Before the request rather than after it: the whole point is to shrink what
	-- this turn sends. Runs on every turn including mid-tool-loop, because a long
	-- uninterrupted sweep is exactly the thing that can fill the window without
	-- the user ever getting a prompt back.
	local dropped = clearOldToolResults(conversation)
	if dropped > 0 then
		Console.appendLine(
			string.format("  Cleared %d characters of old tool output to save context.", dropped),
			"system")
	end

	-- Every block this turn draws — the bubble, the ones a server tool splits off,
	-- and each tool call — belongs to the assistant message it is about to
	-- produce, which lands at the end of the conversation as it stands right now.
	-- Left set for the whole turn deliberately; setBusy clears it at the end.
	Console.setMessage(#conversation + 1)
	local bubble = Console.createBubble()
	local text = ""        -- every text delta of the turn; what the history gets
	local bubbleText = ""  -- only the part belonging to the CURRENT bubble
	local finished = false

	-- A server tool runs mid-stream, so its console block lands below a bubble
	-- that is still being written to, and the text that comes AFTER the search
	-- then renders above the search that produced it. (Our own tools never do
	-- this: they are dispatched in onComplete, once the bubble is finished.) So a
	-- server tool ends the current bubble and the next text starts a new one
	-- below its block. Deferred rather than done on the spot, so consecutive
	-- searches do not leave a row of empty bubbles between them.
	local splitPending = false
	-- Adaptive thinking streams a thinking block whether or not there is a
	-- summary to go with it: a short thought summarises to nothing, and the
	-- deltas arrive as empty strings. The drawer was created on the FIRST delta
	-- whatever it held, so those turns put up a "> thinking" row that opened on
	-- an empty body. Hold off until a delta carries an actual character.
	local thinkingSeen = false
	local function splitBubble()
		if not splitPending then return end
		splitPending = false
		bubble.finishThinking()
		bubble = Console.createBubble()
		bubbleText = ""
		thinkingSeen = false
	end

	-- Puts a tool-call block on screen and registers it so a later result can
	-- find it. Shared by our tools and Anthropic's, which differ only in whether
	-- any arguments exist yet: both split the bubble underneath, both key the
	-- block by id, and both have to stop the spinner immediately when there is no
	-- id, because nothing can ever pair a result to a block that has none.
	local function beginCall(name: string, id: string?, input: { [string]: any }): any
		splitPending = true
		local call = Console.appendToolCall(name, input)
		if id then pendingCalls[id] = call else call.finish() end
		return call
	end

	local function finish()
		if finished then return true end
		finished = true
		return false
	end

	-- Forward-declared and assigned AFTER the call, so stopCurrent must not
	-- capture it by value. Registering the stop handler BEFORE the request also
	-- closes a real gap: Auth.getAccessToken() yields on a token refresh, and
	-- during that window there was previously no handler at all. Stop did
	-- nothing, or worse, referenced a local that had not been assigned yet.
	local stream: any = nil
	local cancelRequested = false
	-- The tool-call block currently executing. It is claimed OUT of pendingCalls
	-- before dispatch, so setBusy's sweep cannot reach it, without this handle
	-- its spinner turns forever after a Stop.
	local runningCall: any = nil
	-- The tool_use blocks onComplete has already committed to the history and
	-- that nothing has answered yet. Stop has to answer them: Anthropic rejects
	-- a tool_use with no matching tool_result, so abandoning a turn here would
	-- poison every later request in the session rather than just this one.
	local unanswered: { any }? = nil
	-- Set once onComplete has put this turn's assistant message into the history.
	-- Stop reads it, because after that point the two rollback branches it used
	-- to fall through to are both wrong — see stopCurrent below.
	local committed = false

	-- Hand the next turn to a fresh task so the UI paints before the request
	-- goes out, and so the recursion is not one ever-deepening call stack.
	-- Both continuation paths below, pause_turn and tool results, used a
	-- copy of these lines.
	--
	-- Declared BELOW `cancelRequested` and not above it, which is not a matter
	-- of taste: a local named before it exists is not that local, it is a nil
	-- global, so the guard below would read nil forever and never fire. The same
	-- trap `lastRequestAt` fell into at the top of this file.
	--
	-- `checkpoint` is passed only by the tool-results path, where every tool_use
	-- in the history has its tool_result beside it and the conversation is
	-- therefore valid to send back. The OTHER caller is pause_turn, where the
	-- assistant message carries a server_tool_use whose result has not arrived
	-- yet: saving there and restoring from it leaves an unanswered tool_use in
	-- the history permanently, which Anthropic rejects on every later request —
	-- a session that is dead and cannot be repaired, traded for a crash window
	-- of a few seconds.
	--
	-- Inside the spawn rather than before it, so the disk write lands in the
	-- same 0.1s the UI was already given to paint. No throttle: every checkpoint
	-- is separated from the next by a whole request, so the rate is bounded by
	-- the network however fast the tools are. pcall because a failed save must
	-- not take the run down with it.
	local function continueTurn(checkpoint: boolean?)
		task.spawn(function()
			if checkpoint and onCheckpoint then
				local ok, err = pcall(onCheckpoint)
				if not ok then warn("[agent] checkpoint failed: " .. tostring(err)) end
			end
			task.wait(0.1)
			-- Re-checked AFTER the wait, and this is the only yield in a run where
			-- Stop can land with nothing left to catch it. Without it: the handler
			-- below runs, prints "Stopped.", clears busy — and 0.1s later this
			-- task starts turn N+1 regardless, spending real tokens and drawing
			-- real tool calls with the Stop button hidden, because busy is false
			-- and nothing sets it back. That is the "I pressed stop and it kept
			-- going" report, and it is not a UI glitch: the turn genuinely ran.
			if cancelRequested then return end
			runTurn(turn + 1)
		end)
	end

	stopCurrent = function()
		if cancelRequested then return end
		cancelRequested = true
		-- Deliberately NOT gated on finish(). That latch means "the stream has
		-- been finalised", and onComplete sets it on its very first line, before
		-- any tool runs. Sharing it made Stop a silent no-op for the whole
		-- tool-execution phase: no "Stopped.", no spinner reset, nothing. That is
		-- precisely the phase worth stopping, because `run` has no timeout and
		-- Luau cannot preempt a chunk that is looping.
		finished = true
		if stream then stream.cancel() end
		bubble.finishThinking()

		if runningCall then
			-- Honest about what Stop can and cannot do: the turn is abandoned, but
			-- a chunk already executing keeps going until it returns on its own.
			runningCall.setResult(
				"stopped — the turn was abandoned, but this call is still running " ..
					"and cannot be interrupted", true)
			runningCall = nil
		end

		-- Leave the history in a shape the next request can build on.
		if unanswered then
			-- Stopped DURING the tools, so the assistant message is already in the
			-- history with its tool_use blocks. They have to be answered rather
			-- than left dangling, and a second assistant message must NOT be added
			-- on top, that would break role alternation as well as the pairing.
			local answers: { any } = {}
			for _, block in ipairs(unanswered) do
				if block.id then
					answers[#answers + 1] = {
						type = "tool_result",
						tool_use_id = block.id,
						content = "stopped by the user",
					}
				end
			end
			if #answers > 0 then
				table.insert(conversation, { role = "user", content = answers })
			end
			unanswered = nil
		elseif committed then
			-- Stopped in the gap between two turns: this turn's assistant message
			-- and every tool_result answering it are ALREADY in the history, and
			-- what Stop is actually cancelling is the continuation queued after
			-- them. So there is nothing to add, and both branches below would do
			-- damage — the first appends a second assistant message holding text
			-- that is already up there, the second deletes a tool_result message
			-- and leaves its tool_use unanswered for the rest of the session.
		elseif text ~= "" then
			-- Stopped mid-stream. Partial text becomes a normal assistant message
			-- so roles still alternate; a partial tool_use is dropped, since it has
			-- no tool_result to pair with.
			bubble.setText(bubbleText)
			table.insert(conversation, { role = "assistant", content = text })
		elseif turn == 1 and #conversation > 0 then
			-- Nothing generated yet: roll the user message back entirely.
			table.remove(conversation, #conversation)
		end

		Console.appendLine("Stopped.", "info")
		setBusy(false)
	end

	-- Stamped as the request goes out, which is close enough: the server writes
	-- the cache when it serves this, and the difference is seconds against
	-- COLD_AFTER. Every request in the session comes through here, tool-loop
	-- recursions included, so a long sweep keeps the cache correctly marked warm.
	lastRequestAt = os.time()

	stream = Provider.wire.streamMessage({
		model = Settings.model(),
		system = Settings.system(),
		messages = conversation,
		effort = Settings.effort(),
		tools = buildTools(),
		-- How many searches are allowed, not what a search IS. Anthropic and OpenAI
		-- put server tools in their tool arrays; OpenRouter uses a body-level plugin.
		-- Those wire details are the provider's business, not Agent's.
		webSearch = Settings.webSearchMaxUses(),
	}, {
		onThinking = function(delta: string)
			if not thinkingSeen then
				-- Leading blank deltas are dropped with the empty ones; a summary
				-- that starts on a newline reads the same without it.
				if not delta:match("%S") then return end
				thinkingSeen = true
			end
			splitBubble()
			-- The bubble creates its thinking block on demand, above the answer.
			bubble.thinking().append(delta)
		end,

		onText = function(delta: string)
			splitBubble()
			text ..= delta
			bubbleText ..= delta
			bubble.setText(bubbleText)
		end,

		-- Fired when the model STARTS writing a call to one of our tools, before
		-- its arguments have streamed. The block goes up empty and is filled in
		-- twice: setInput when the input parses, setResult when the tool has run.
		-- Without this the header only appeared once the whole message was over,
		-- so a `write` of a large file was minutes of a console showing nothing
		-- but the reply above it.
		--
		-- Same bubble split as a server tool, and for the same reason: the block
		-- lands below a bubble that may still be written to, so the text that
		-- comes after the call must start a new bubble under it.
		onToolUseStart = function(id: string?, name: string)
			beginCall(name, id, {})
		end,

		-- Each fragment of the arguments as the model writes them. The block is
		-- already on screen from onToolUseStart, so this only feeds it; a fragment
		-- for an id we never saw start has nowhere to go and is dropped rather
		-- than opening a second block halfway through a call.
		onToolInput = function(id: string?, fragment: string)
			local call = id and pendingCalls[id] or nil
			if call then call.appendInput(fragment) end
		end,

		onServerToolUse = function(name: string, id: string?, input: any)
			-- Header goes up now, results are filled in when they arrive: the API
			-- runs these itself and sends the call and its result as two separate
			-- blocks, so waiting for both would leave the console silent for the
			-- whole search.
			beginCall(name, id, type(input) == "table" and input or {})
		end,

		onServerToolResult = function(name: string, toolUseId: string?, content: any)
			local body = formatServerResult(content)
			local call = if toolUseId then pendingCalls[toolUseId] else nil
			if call then
				pendingCalls[toolUseId :: string] = nil
				call.setResult(body)
			else
				-- No matching call block seen; still show the result rather than
				-- dropping it on the floor.
				Console.appendToolCall(name, {}, body)
			end
		end,

		onComplete = function(result: any)
			if finish() then return end

			bubble.finishThinking()

			if not result.ok then
				warn("[agent] " .. tostring(result.error))
				bubble.setError(tostring(result.error))
				-- Only drop the user's message on the FIRST turn. Later turns end
				-- in tool_result blocks that pair with tool_use blocks already in
				-- the history; removing one would desync the pairing and every
				-- retry would fail with "unexpected tool_use_id".
				if turn == 1 and #conversation > 0 then
					table.remove(conversation, #conversation)
				end
				setBusy(false)
				return
			end

			-- Final render, in case the last deltas landed inside the throttle
			-- window. The streamed text is used rather than result.text because
			-- only it is scoped to the current bubble, result.text is every text
			-- block of the turn, including the ones already drawn in earlier
			-- bubbles above a search. A turn that only thought and called a tool
			-- has no text at all, and gets no empty render.
			if bubbleText ~= "" then
				bubble.setText(bubbleText)
			end

			-- Counted here rather than in the final-turn block below: a tool-use
			-- turn returns early, and its tokens are just as billed.
			if result.usage then
				local prompt = (result.usage.input_tokens or 0)
					+ (result.usage.cache_read_input_tokens or 0)
					+ (result.usage.cache_creation_input_tokens or 0)
				totals.input += prompt
				totals.cached += result.usage.cache_read_input_tokens or 0
				-- Kept apart from `cached` rather than summed with it: a read is
				-- charged at a tenth and a write at one and a quarter, so one number
				-- for both is the one thing a cache figure must not be.
				totals.cacheWrite += result.usage.cache_creation_input_tokens or 0
				totals.output += result.usage.output_tokens or 0
				totals.requests += 1
				-- Same counter, different window: totals is the session, this is
				-- since the reader's last message, which is what a budget is for.
				budgetSpent += result.usage.output_tokens or 0
				-- Assigned, not accumulated. This is the only place the real prompt
				-- size is known: the conversation table's character count is an
				-- estimate, and the system prompt and tool schemas are not in it at
				-- all — they are a fixed several thousand tokens the panel would
				-- otherwise report as zero. Set on EVERY turn including a tool-use
				-- one, because a tool sweep is exactly when the window fills.
				totals.prompt = prompt
			end

			-- One assistant message holding ALL content blocks. Splitting text and
			-- tool_use into separate messages breaks the tool_use/tool_result
			-- pairing Anthropic validates.
			local assistantContent: { any } = {}
			local toolUses: { any } = {}
			for _, block in ipairs(result.contentBlocks or {}) do
				if block.type == "thinking" and block.signature then
					-- REQUIRED inside a tool-use turn, not an optimisation: the model
					-- pauses mid-response to call the tool and resumes the same
					-- response when the result comes back, so the reasoning that
					-- chose the call has to still be there. Anthropic's rule is that
					-- the run of thinking blocks in the latest assistant message must
					-- match what it generated, they cannot be reordered, edited, or
					-- partly dropped. Replayed verbatim: under display "summarized"
					-- the text is a summary, and the signature is what the server
					-- decrypts to recover the real thinking.
					table.insert(assistantContent, {
						type = "thinking",
						thinking = block.thinking,
						signature = block.signature,
					})
				elseif block.type == "redacted_thinking" and block.raw then
					-- Safety-redacted reasoning: no deltas and no readable text, so
					-- the whole block lands at content_block_start and the raw copy IS
					-- the block. Matching only on "thinking" would drop these silently
					-- and break the same pairing.
					table.insert(assistantContent, block.raw)
				elseif block.type == "text" and block.text ~= "" then
					table.insert(assistantContent, {
						type = "text",
						text = block.text,
						citations = block.citations,
					})
				elseif block.type == "tool_use" then
					table.insert(assistantContent, {
						type = "tool_use",
						id = block.id,
						name = block.name,
						input = toolInput(block),
						-- Opaque and optional. OpenAI uses this to retain the exact
						-- Responses function_call item on function-only turns; every
						-- other provider leaves it nil and keeps the old history shape.
						providerState = block.providerState,
					})
					table.insert(toolUses, block)
				elseif block.type == "server_tool_use" then
					-- Anthropic ran this one. We replay it but never dispatch it,
					-- so it is deliberately NOT added to toolUses.
					table.insert(assistantContent, {
						type = "server_tool_use",
						id = block.id,
						name = block.name,
						input = toolInput(block),
					})
				elseif isServerResult(block.type) and block.raw then
					-- Server tool results arrive complete and are replayed verbatim.
					-- Dropping one while keeping its server_tool_use would leave an
					-- unanswered call in the history. Matched by an explicit list,
					-- not "has a raw field": thinking blocks have one too, and their
					-- raw copy is the empty shell from content_block_start, before
					-- any delta filled it in.
					table.insert(assistantContent, block.raw)
				end
			end

			local storedContent = if #assistantContent > 0 then assistantContent else result.text
			-- Codex can send an empty response as a continuation bridge. Its
			-- native loop records no invented message in that case, and inserting
			-- "(empty)" changes the next prompt as well as polluting restored
			-- sessions. Only OpenAI opts into omission; the other providers retain
			-- the previous non-empty fallback exactly.
			if not result.omitEmpty or (storedContent ~= nil and storedContent ~= "") then
				table.insert(conversation, {
					role = "assistant",
					content = storedContent ~= nil and storedContent or "(empty)",
				})
				committed = true
			end

			-- Run the tools. Every tool_use needs a matching tool_result, including
			-- ones whose input failed to parse, an unanswered tool_use is a
			-- protocol error, so failures go back as error text.
			--
			-- Published before the loop so a Stop landing mid-dispatch knows which
			-- tool_use blocks it has to answer on the way out.
			unanswered = toolUses
			local toolResults: { any } = {}
			for _, block in ipairs(toolUses) do
				-- Checked per tool, not just once: a turn can ask for several, and a
				-- Stop pressed during the first should not be followed by the rest.
				if cancelRequested then
					break
				end
				local toolResult: string
				-- Whether the input never parsed, as opposed to a tool that ran and
				-- returned an error string. Only the first is a protocol-level
				-- failure, and only it sets is_error on the result below.
				local inputFailed = false
				-- The block onToolUseStart put up while the input was streaming.
				-- Claimed here so the cleanup in setBusy cannot finish a block this
				-- loop is about to write a result into.
				local call = block.id and pendingCalls[block.id] or nil
				if block.id then pendingCalls[block.id] = nil end
				if block.inputParsed then
					-- The arguments only exist now; the header has been up since the
					-- model started writing the call. The fallback covers a stream
					-- that somehow produced no start event, dispatch blocks this
					-- thread for as long as the tool takes, and catalog/run/web calls
					-- take seconds, so a spinner has to be saying which call the wait
					-- belongs to either way.
					if call then
						call.setInput(block.inputParsed)
					else
						call = Console.appendToolCall(block.name, block.inputParsed)
					end
					-- Published so Stop can finish this block's spinner while the
					-- call is still running, and cleared after so a later Stop does
					-- not write a result over a block that already has one.
					runningCall = call
					toolResult = Tools.dispatch(term, block.name, block.inputParsed)
					runningCall = nil
					-- A tool_result whose content is "" is rejected outright, and on
					-- turn > 1 it cannot be rolled back: the tool_use is already in
					-- the history above, so every retry resends the same poisoned
					-- pair and fails identically, a dead session from one command
					-- that happened to print nothing. Reached by `cat` of an empty
					-- script, `diff` of two identical ones, bare `echo`, sort/uniq/tr
					-- with no stdin, and anything redirected to /dev/null. Guarded
					-- here rather than in each handler because "" is a correct result
					-- for /sh; it is only invalid on the wire.
					if toolResult == "" then toolResult = "(no output)" end
					call.setResult(toolResult)
				else
					inputFailed = true
					-- Naming the stop reason is what makes this recoverable: on
					-- "max_tokens" the input was cut off mid-JSON, and the answer
					-- is to send less rather than to send the same thing again.
					toolResult = string.format(
						"error: tool input was not valid JSON (stop_reason: %s) — if it was truncated, retry with a smaller input",
						tostring(result.stopReason))
					-- The raw fragment is the only thing that says WHERE the JSON
					-- died, so it goes in the expandable body rather than being
					-- summarised away. warn() as well: MAX_DETAIL_CHARS clips the
					-- body, and a truncated multiedit is exactly the case that
					-- overruns it, the Output window keeps the whole thing.
					warn(string.format("[agent] %s: unparsed tool input (stop_reason: %s): %s",
						tostring(block.name), tostring(result.stopReason), tostring(block.input)))
					local raw = { raw_input = tostring(block.input) }
					if call then
						-- Same block, now red and carrying the fragment. It has been
						-- on screen spinning since the model started the call, so
						-- appending a second one would leave the first hanging.
						call.setInput(raw)
						call.setResult(toolResult, true)
					else
						Console.appendToolCall(
							tostring(block.name) .. " parse error", raw, toolResult, true)
					end
				end
				table.insert(toolResults, {
					type = "tool_result",
					tool_use_id = block.id,
					content = toolResult,
					-- `or nil` so the field is absent rather than false: this is the
					-- documented signal for input that could not be parsed, and now
					-- that eager_input_streaming is on it is a live path rather than
					-- a max_tokens rarity. A tool that ran and failed is NOT this;
					-- its error is an ordinary result the model reads and retries.
					is_error = inputFailed or nil,
				})
			end
			-- Capped HERE and not in Tools.dispatch: setResult() above has already
			-- handed the Console the whole thing, so the panel keeps the full
			-- output and only the history pays. After the loop rather than inside
			-- it, because the budget is a property of the batch, and cutting
			-- twice would leave a result carrying two truncation notes.
			capTurn(toolResults)

			-- pause_turn: a long-running server tool was interrupted mid-turn.
			-- A yielding tool outlasts the Stop pressed while it ran, with `run`
			-- that is the ordinary case, not an edge one, since a chunk that loops
			-- cannot be interrupted at all. Whatever it eventually returned is
			-- dropped here rather than quietly starting another turn on behalf of
			-- someone who asked for the opposite.
			if cancelRequested then
				return
			end

			-- Anthropic's pause_turn and Codex's response.end_turn=false both mean
			-- sample again with the committed history; there are no local tool
			-- results to attach in this branch.
			if (result.stopReason == "pause_turn" or result.stopReason == "continue_turn")
				and #toolResults == 0 then
				continueTurn()
				return
			end

			if #toolResults > 0 then
				-- All results in ONE user message. Anthropic requires every
				-- tool_result for a turn to arrive together.
				table.insert(conversation, { role = "user", content = toolResults })
				-- Answered, so a later Stop must not answer them a second time.
				unanswered = nil
				-- Checkpointed: every tool_use above now has its tool_result, so
				-- this is a history a crash can be restored from.
				continueTurn(true)
				return
			end

			-- Nothing was asked of a tool, so this is where the turn would end.
			-- Reached only past the pause_turn and tool-result branches above, so
			-- every tool_use in the history already has its result and the
			-- conversation is valid to send back and to checkpoint.
			local nudge = budgetContinuation()
			if nudge then
				Console.setMessage(#conversation + 1)
				Console.appendLine(nudge, "system")
				Console.setMessage(0)
				table.insert(conversation, { role = "user", content = nudge })
				continueTurn(true)
				return
			end

			if result.usage then
				-- input_tokens is only the UNCACHED remainder, not the prompt
				-- size. Printing it alone made a working cache look like a broken
				-- counter: once the system prompt, the tools and the whole
				-- conversation are cached, the fresh part of a follow-up turn
				-- really is a couple of tokens, and "2 in" was the truth told in
				-- the most alarming possible way. The real prompt is fresh + read
				-- + written, so show all three.
				local usage = result.usage
				local fresh = usage.input_tokens or 0
				local cacheRead = usage.cache_read_input_tokens or 0
				local cacheWrite = usage.cache_creation_input_tokens or 0
				local parts = { string.format("%d in", fresh + cacheRead + cacheWrite) }
				if cacheRead > 0 then
					table.insert(parts, string.format("%d cached", cacheRead))
				end
				if cacheWrite > 0 then
					table.insert(parts, string.format("%d new to cache", cacheWrite))
				end
				table.insert(parts, string.format("%d out", usage.output_tokens or 0))
				Console.appendLine("  " .. table.concat(parts, " · "), "system")
			end
			setBusy(false)
		end,

		-- A transient failure the provider is going to retry by itself. Printed
		-- rather than swallowed: the turn is about to sit there for several
		-- seconds, and the spinner alone reads as the request having died.
		onRetry = function(reason: string, wait: number, attempt: number, ofAttempts: number)
			Console.appendLine(string.format(
				"  %s — retrying in %.0fs (%d/%d)", reason, wait, attempt, ofAttempts), "system")
		end,

		onError = function(message: string)
			if finish() then return end
			warn("[agent] " .. message)
			-- Without this the thinking header keeps spinning on a dead request.
			bubble.finishThinking()
			bubble.setError(message)
			if turn == 1 and #conversation > 0 then
				table.remove(conversation, #conversation)
			end
			setBusy(false)
		end,
	})

	-- Stop pressed while the request was still being set up: the handle only
	-- exists now, so close it here.
	if cancelRequested and stream then
		stream.cancel()
	end
end

-- Entry point
-- What the user currently has open, and where their cursor is. "fix this
-- function" is unanswerable without it and costs a grep to guess at; with it,
-- it is a `sed -n` away.
--
-- Attached to EVERY user message rather than only the first. A cursor captured
-- once at session start is asserting a position the user left ten turns ago,
-- and nothing in the text says it is stale, a wrong cursor is worse than no
-- cursor. This costs nothing to keep current: the newest message sits after the
-- conversation cache breakpoint (see withMessageCache in Claude), so re-sending
-- a changed line here never invalidates the cached prefix.
--
-- Which tab is in FRONT is a separate question from which are open, and this
-- used to say there was no way to ask it — "ScriptDocument cannot say which tab
-- is in front" — and listed all six with equal weight as a result. That was
-- wrong about the API, not about ScriptDocument: `StudioService.ActiveScript` is
-- a read-only Instance naming exactly the script being edited. Fs.openDocuments
-- puts it first and flags it, so "fix this function" resolves to one file
-- instead of six candidates, and the entry that survives the cap below is always
-- the one that matters rather than whichever GetScriptDocuments happened to
-- return first.
--
-- Still a LIST, not just the active one: the others are real context (a model
-- asked to move code between two open files should know both are open), and
-- nil is a real answer for ActiveScript whenever the viewport is in front.
local MAX_OPEN_DOCS = 6
-- The count cap alone does not bound this. instancePath walks to game joining
-- .Name, and neither nesting depth nor a name's length has a limit, so six
-- entries is six unbounded strings. Whole entries are dropped rather than
-- individual paths cut: a truncated path is one the model cannot hand to
-- cat/sed, which costs the turn this hint exists to save. The budget is checked
-- before an entry is added, not after, so the true bound is this plus one entry
-- — the remaining slack is a single path, which is as tight as it gets without
-- cutting one. Sized so the ordinary six-document case never reaches it.
local MAX_OPEN_CHARS = 600

local function editorContext(): string
	local docs = Fs.openDocuments()
	if #docs == 0 then
		return ""
	end
	local parts: { string } = {}
	local used = 0
	for index, entry in ipairs(docs) do
		if index > MAX_OPEN_DOCS or used > MAX_OPEN_CHARS then
			parts[#parts + 1] = string.format("… %d more", #docs - (index - 1))
			break
		end
		-- instancePath, not GetFullName: this is a path the model can hand
		-- straight back to cat/sed/grep. GetFullName's dotted form resolves to
		-- nothing here, which would make the hint cost a turn instead of saving one.
		local label = Fs.instancePath(entry.inst)
		-- The one the user is actually looking at, named as such. Without this the
		-- list is six paths in an undocumented order and "this file" is a guess.
		if entry.active then
			label ..= " [ACTIVE]"
		end
		-- GetSelection returns (line, char); the extra parens take the line.
		local ok, line = pcall(function()
			return (entry.doc:GetSelection())
		end)
		if ok and type(line) == "number" then
			-- Where they are scrolled to is a different question from where the
			-- caret is, and it is the one that answers "this function".
			local viewOk, first, last = pcall(function()
				return entry.doc:GetViewport()
			end)
			label = (viewOk and type(first) == "number" and type(last) == "number")
				and string.format("%s (cursor line %d, showing %d-%d)", label, line, first, last)
				or string.format("%s (cursor line %d)", label, line)
		end
		parts[#parts + 1] = label
		used += #label + 2   -- + the ", " that will join it
	end
	return "\n\n[open in the editor: " .. table.concat(parts, ", ") .. "]"
end

function Agent.send(text: string, isLoggedIn: () -> boolean)
	if busy then return end
	if not isLoggedIn() then
		Console.appendLine("Not logged in. Use /login.", "error")
		return
	end

	-- Shown to the model, not to the user: the console echoes what was typed.
	-- Anchored to the message it is about to become, so Find can scroll back to
	-- it later; the index is what the insert below lands on.
	Console.setMessage(#conversation + 1)
	Console.appendLine(text, "user")
	Console.setMessage(0)
	table.insert(conversation, { role = "user", content = text .. editorContext() })
	-- Armed per message and reset here, not at session start: a budget is a
	-- property of the request that asked for one, and the next message without
	-- `+500k` in it turns the whole mechanism back off.
	budget = parseTokenBudget(text)
	budgetSpent, continuations, lastDelta, lastChecked = 0, 0, 0, 0
	-- Before the first request, not after it. Otherwise the whole of turn one is
	-- unsaved, and a crash inside it puts the session back to before the message
	-- was ever typed — the one loss the user has to retype by hand rather than
	-- just wait out.
	if onCheckpoint then
		local saved, err = pcall(onCheckpoint)
		if not saved then warn("[agent] checkpoint failed: " .. tostring(err)) end
	end
	setBusy(true)
	runTurn(1)
end

-- Self-test
-- Both of these shape what goes on the wire, and both fail in ways that only
-- show up as a dead session: a cut that lands mid-codepoint makes JSONEncode
-- reject the request, and a cleared tool_result that loses its pairing or comes
-- back empty poisons every later turn.
function Agent.selfTest(): (boolean, string?)
	-- Token budget: what arms it, and the false positive that must not.
	for _, case in ipairs({
		{ "+500k", 500000 },
		{ "  +2m refactor the whole thing", 2000000 },
		{ "refactor the whole thing +500k", 500000 },
		{ "port the module +1.5m.", 1500000 },
		{ "use 500k tokens on this", 500000 },
		{ "please spend 2m tokens getting it right", 2000000 },
		-- Prose that looks like a budget. Both anchors exist for this line: a
		-- bare "+2k" in the middle of a sentence is a diff stat, not a target.
		{ "the diff is +2k lines, trim it", false },
		{ "fix the parser", false },
	}) do
		local text, want = case[1] :: string, case[2]
		local got = parseTokenBudget(text)
		if want == false then
			if got ~= nil then
				return false, string.format("parseTokenBudget armed on %q (%d)", text, got)
			end
		elseif got ~= want then
			return false, string.format("parseTokenBudget(%q) = %s, expected %d",
				text, tostring(got), want :: number)
		end
	end

	-- The decision, driven directly. Restored afterwards because these are the
	-- live counters, and /selftest runs mid-session.
	local savedBudget, savedSpent = budget, budgetSpent
	local savedCont, savedDelta, savedChecked = continuations, lastDelta, lastChecked
	budget, budgetSpent, continuations, lastDelta, lastChecked = nil, 0, 0, 0, 0
	local ok, err = pcall(function(): string?
		if budgetContinuation() ~= nil then
			return "budgetContinuation fired with no budget asked for"
		end
		budget, budgetSpent = 100000, 10000
		if budgetContinuation() == nil then
			return "budgetContinuation stopped at 10% of target"
		end
		-- At the threshold the turn is finished, not nudged.
		budgetSpent = 90000
		if budgetContinuation() ~= nil then
			return "budgetContinuation nudged past COMPLETION_THRESHOLD"
		end
		-- Diminishing: three rounds in, and two quiet ones in a row. Without this
		-- a model that has run out of work is nudged until it spends the budget
		-- on filler.
		budget, budgetSpent = 100000, 20000
		continuations, lastDelta, lastChecked = 3, 10, 20000
		if budgetContinuation() ~= nil then
			return "budgetContinuation ignored diminishing returns"
		end
		return nil
	end)
	budget, budgetSpent = savedBudget, savedSpent
	continuations, lastDelta, lastChecked = savedCont, savedDelta, savedChecked
	if not ok then return false, "budget check threw: " .. tostring(err) end
	if err then return false, err :: string end

	-- Under the cap: byte-identical, no marker bolted on.
	local short = "hello\nworld"
	if forModel(short) ~= short then
		return false, "forModel altered a result under the cap"
	end

	-- Sizes are derived from the cap, never written as literals: the fixtures
	-- have to stay ON the far side of it, and a hand-typed 40000 silently stops
	-- testing anything the moment the cap is raised past it.
	--
	-- Over the cap, no newline anywhere, and the cut lands mid-codepoint: the
	-- leading "a" pushes every 2-byte "e-acute" out of alignment, so the byte
	-- just past the limit is a continuation byte and safeCut has to step back off
	-- it. That holds for any even cap. U+00E9 is spelled out as its two UTF-8
	-- bytes so the thing being tested, a cut landing between them, is on the
	-- page rather than hidden inside an escape.
	local multibyte = "a" .. string.rep(string.char(0xC3, 0xA9), MODEL_RESULT_CHARS)
	local cut = forModel(multibyte)
	if #cut >= #multibyte then
		return false, "forModel did not shorten an oversized result"
	end
	if not string.find(cut, "characters truncated", 1, true) then
		return false, "forModel dropped the truncation marker"
	end
	if utf8.len(cut) == nil then
		return false, "forModel cut mid-codepoint and produced invalid UTF-8"
	end
	if #cut > MODEL_RESULT_CHARS + 200 then
		return false, "forModel overshot the cap"
	end

	-- With newlines it should stop on one, leaving whole lines behind. The kept
	-- half ends in a newline, then forModel adds its own before the marker, so a
	-- line-boundary cut shows up as two in a row. 11 chars per line, plus slack,
	-- to land comfortably past the cap whatever it is set to.
	local lineCount = math.floor(MODEL_RESULT_CHARS / 11) + 100
	local cutLines = forModel(string.rep("0123456789\n", lineCount))
	if not string.find(cutLines, "\n\n%.%.%. %[") then
		return false, "forModel did not stop on a line boundary"
	end

	-- capTurn. Both directions matter and both fail silently: too eager and it
	-- truncates ordinary sweeps that were never near the budget, too slack and
	-- one turn of parallel calls buries the window in a single user message that
	-- can never be taken back out.
	local function batch(sizes: { number }): { any }
		local blocks: { any } = {}
		for index, size in ipairs(sizes) do
			blocks[index] = { type = "tool_result", tool_use_id = "t" .. index,
				content = string.rep("y", size) }
		end
		return blocks
	end
	local function sumOf(blocks: { any }): number
		local total = 0
		for _, entry in ipairs(blocks) do
			total += #entry.content
		end
		return total
	end

	-- A normal sweep: four small results must come back byte-identical.
	local sweep = batch({ 10, 200, 3000, 40 })
	local sweepBefore = sumOf(sweep)
	capTurn(sweep)
	if sumOf(sweep) ~= sweepBefore then
		return false, "capTurn truncated a turn that was nowhere near the budget"
	end

	-- Six results that each clear the per-result cap on their own. Without the
	-- batch cap this is 6 x MODEL_RESULT_CHARS on the wire.
	local floodSizes: { number } = {}
	for i = 1, 6 do
		floodSizes[i] = MODEL_RESULT_CHARS + 50000
	end
	local flood = batch(floodSizes)
	capTurn(flood)
	-- Slack for one truncation note per result; the point is the order of
	-- magnitude, not the byte.
	if sumOf(flood) > MODEL_TURN_CHARS + 6 * 400 then
		return false, string.format("capTurn let a turn through at %d chars (budget %d)",
			sumOf(flood), MODEL_TURN_CHARS)
	end
	for _, entry in ipairs(flood) do
		if #entry.content == 0 then
			return false, "capTurn produced an empty tool_result, which the API rejects"
		end
	end

	-- Fair share: three tiny results must not cost the big one its full
	-- per-result allowance. Splitting the budget evenly would leave it a quarter.
	local lopsided = batch({ 5, 5, 5 })
	lopsided[4] = { type = "tool_result", tool_use_id = "big",
		content = string.rep("w", 5 * MODEL_RESULT_CHARS) }
	capTurn(lopsided)
	if #lopsided[4].content < MODEL_RESULT_CHARS then
		return false, string.format(
			"capTurn gave the only large result %d chars; small siblings should have released their share",
			#lopsided[4].content)
	end

	-- Clearing. Sizes derive from the thresholds for the same reason the
	-- truncation fixtures do, and here it matters twice: the warm case has to sit
	-- BETWEEN TRIGGER_CHARS and the urgent line, so a hand-typed size stops
	-- exercising the gate the moment either constant moves.
	local function pairedHistory(count: number, size: number): { any }
		local body = string.rep("x", size)
		local messages: { any } = {}
		for i = 1, count do
			table.insert(messages, { role = "assistant", content = {
				{ type = "tool_use", id = "t" .. i, name = "bash", input = { command = "ls" } },
			} })
			table.insert(messages, { role = "user", content = {
				{ type = "tool_result", tool_use_id = "t" .. i, content = body },
			} })
		end
		return messages
	end

	-- Driven directly, because which side of cacheIsCold() a history falls on is
	-- the whole decision the pass makes.
	local savedStamp = lastRequestAt

	-- Cold: nothing has been sent, so no prefix is cached and the pass is free.
	-- 12 paired calls, over the trigger and under the urgent line.
	local coldSize = TRIGGER_CHARS // 10
	local big = string.rep("x", coldSize)
	lastRequestAt = nil
	local messages = pairedHistory(12, coldSize)

	if clearOldToolResults(messages) <= 0 then
		return false, "clearOldToolResults did nothing to an oversized history on a cold cache"
	end

	local seen: { any } = {}
	for _, message in ipairs(messages) do
		if type(message.content) == "table" then
			for _, block in ipairs(message.content) do
				if block.type == "tool_result" then table.insert(seen, block) end
			end
		end
	end
	if #seen ~= 12 then
		return false, "clearOldToolResults changed the number of tool_result blocks"
	end
	for i, block in ipairs(seen) do
		if type(block.content) ~= "string" or block.content == "" then
			return false, "clearOldToolResults left tool_result " .. i .. " empty"
		end
		if i > 12 - KEEP_RECENT and block.content ~= big then
			return false, "clearOldToolResults touched one of the recent results"
		end
		if i <= 12 - KEEP_RECENT and block.content ~= CLEARED then
			return false, "clearOldToolResults missed an old result"
		end
	end

	-- Idempotent: the second pass is now under the trigger and must not cost
	-- another cache re-write.
	if clearOldToolResults(messages) ~= 0 then
		return false, "clearOldToolResults ran again with nothing left to save"
	end

	-- A small history is never touched.
	if clearOldToolResults({ { role = "user", content = "hi" } }) ~= 0 then
		return false, "clearOldToolResults acted on a small history"
	end

	-- Warm: the same history moments after a request. Clearing now would re-write
	-- the entire cached prefix to save a fraction of it, which is the failure this
	-- gate exists to prevent, and it is silent, so only a test catches it.
	--
	-- Both warm cases need an urgent line to sit either side of, so both are
	-- skipped when the provider cannot name the model's window, and when the
	-- window is small enough that 12 x coldSize is already past the line — there
	-- is then no size that is over the trigger and under the urgent line at once.
	local urgent = urgentChars()
	lastRequestAt = os.time()
	if urgent and urgent > 12 * coldSize then
		if clearOldToolResults(pairedHistory(12, coldSize)) ~= 0 then
			return false, "clearOldToolResults re-wrote a warm cached prefix to save a fraction of it"
		end

		-- Past the urgent line: the window is now the risk rather than the cache,
		-- and nothing else here reclaims anything, so it has to clear anyway.
		if clearOldToolResults(pairedHistory(12, urgent // 10)) <= 0 then
			return false, "clearOldToolResults left a history near the context window uncleared"
		end
	end

	lastRequestAt = savedStamp

	-- The context breakdown's bucketing. The classification that matters is that
	-- a tool_result rides inside a USER message: reading the message role instead
	-- of the block type puts the largest bucket in an agent session — everything
	-- the tools returned — under "Your messages", which is wrong in the one
	-- direction nobody would question, since a user message plausibly holds text.
	local mixed: { any } = {
		{ role = "user", content = "find the bug" },
		{ role = "assistant", content = {
			{ type = "text", text = "looking" },
			{ type = "tool_use", id = "t1", name = "bash", input = { command = "grep -rn x ." } },
		} },
		{ role = "user", content = {
			{ type = "tool_result", tool_use_id = "t1", content = string.rep("h", 500) },
		} },
	}
	local buckets = historyBuckets(mixed)
	if buckets.toolResults ~= 500 then
		return false, string.format("historyBuckets put %d chars of tool_result under toolResults, want 500",
			buckets.toolResults)
	end
	if buckets.user ~= #"find the bug" then
		return false, string.format(
			"historyBuckets counted %d chars as the user's; a tool_result was misfiled as typed text",
			buckets.user)
	end
	if buckets.assistant ~= #"looking" then
		return false, "historyBuckets lost the assistant's text, or swept a tool_use into it"
	end
	if buckets.toolCalls ~= #"grep -rn x ." then
		return false, "historyBuckets did not count the tool_use input"
	end
	-- The invariant clearOldToolResults rides on: splitting the walk must not
	-- change what it totals, or the trigger silently measures something else.
	local summed = buckets.user + buckets.assistant + buckets.toolCalls + buckets.toolResults
	if historyChars(mixed) ~= summed then
		return false, "historyChars and historyBuckets disagree about the same history"
	end

	return true
end

return Agent
