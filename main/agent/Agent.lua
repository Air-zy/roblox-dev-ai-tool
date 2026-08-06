-- Agent.luau — the conversation and the streaming tool-use loop.
--
-- This replaces the old sendToClaude / sendToClaude_continue pair. Those were
-- ~90% identical, and the drift between them was a real bug: the continue path
-- omitted onToolUseStart, which used to gate tool-input parsing, so every
-- follow-up turn sent `input: []` and Anthropic rejected it. One function means
-- one code path to keep correct.

local ui = script.Parent.Parent:WaitForChild("ui")

local Claude = require(script.Parent:WaitForChild("Claude"))
local Tools = require(script.Parent:WaitForChild("Tools"))
local Console = require(ui:WaitForChild("Console"))
local Settings = require(ui:WaitForChild("Settings"))

local Agent = {}

-- There is deliberately NO cap on the tool-use loop, which is what Claude Code
-- does: `maxTurns` (src/query.ts) is optional and left unset in its interactive
-- path, enforced only for `--max-turns`, the SDK and subagents. A turn count of
-- 40 was stopping real work mid-refactor, and the thing it was guarding against
-- is already covered — the loop only continues while the model asks for more
-- tools, Stop and Escape both cancel, and clearOldToolResults keeps the history
-- from growing without bound. runTurn recurses through task.spawn, so depth
-- costs no stack either. `turn` survives as the depth, which the rollback paths
-- below still need to tell the first turn from the rest.

-- Block types Anthropic executes and returns complete; replayed as-is.
local SERVER_RESULT_BLOCKS: { [string]: boolean } = {
	web_search_tool_result = true,
	web_fetch_tool_result = true,
	code_execution_tool_result = true,
}

-- tool_use.input must be a JSON *object* on the wire, and Roblox's encoder turns
-- an empty Lua table into `[]`. That rejection is not a one-turn failure: the
-- block is already in the history, so every later request fails on the same
-- index — "messages.27.content.1.tool_use.input: Input should be an object" —
-- until the conversation is cleared. It fires whenever the accumulated input
-- JSON does not parse, which fine-grained tool streaming makes possible: an
-- input cut short by max_tokens arrives as invalid JSON rather than being
-- buffered and validated. `edits` payloads are the longest thing the model
-- sends, so multiedit is where it shows up.
--
-- Roblox has no object sentinel, so the fallback carries the raw fragment
-- instead of nothing: an object either way, and it shows what was cut off. This
-- is what Anthropic's own guidance says to do — "if you need to pass invalid
-- JSON back to the model in an error response block, you may wrap it in a JSON
-- object … with a reasonable key" — so a truncated call costs one corrective
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

-- =============================================================================
-- What a tool result costs
-- =============================================================================
-- A tool result goes into `conversation` and stays there for the rest of the
-- session, re-read on every later turn. `Shell.run` returns whatever the
-- command produced with no ceiling, so one `cat` of a large ModuleScript or one
-- `ls -R /` is tens of thousands of tokens paid over and over — the only thing
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
-- read from a listing would mean parsing the command in Agent — where
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
-- still sees everything — only the copy going on the wire is cut.
local MODEL_RESULT_CHARS = 100000

-- Cutting a byte string at a fixed offset can land mid-codepoint, and
-- JSONEncode rejects invalid UTF-8 — a truncation that kills the request is
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
-- this file — which makes it also the largest way to blow the window: six calls
-- that each stop just under MODEL_RESULT_CHARS put 600 000 characters into a
-- single message, and once that pair is in the history it is there for good.
--
-- Claude Code caps the same thing (MAX_TOOL_RESULTS_PER_MESSAGE_CHARS) and
-- spills the largest blocks to a file, handing the model a path. A plugin has
-- nowhere to spill, so the big ones are simply cut harder.
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
-- blob that exists only so the result can be replayed on the next turn — it is
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
-- the session — turn web search on afterwards and the stale breakpoint was still
-- sitting on `catalog` while a fresh one went on web_search. Anthropic caps a
-- request at 4 cache_control blocks across system + tools + messages, so two in
-- tools leaves no headroom and the next one added fails the whole request.
--
-- Tool ORDER is load-bearing and must not vary between turns: definitions render
-- ahead of everything else in the request, and caching is a prefix match, so a
-- reorder invalidates the system and conversation breakpoints too. The registry
-- sorts; web search is appended last so toggling it only ever invalidates from
-- the end of the tool block onward.
local function buildTools(): { any }
	local tools = Tools.definitions()
	local searches = Settings.webSearchMaxUses()
	if searches > 0 then
		table.insert(tools, Claude.webSearchTool(searches))
	end
	return tools
end

local term: any = nil
local conversation: { any } = {}
local busy = false
local onBusyChanged: ((boolean) -> ())? = nil
-- Set while a turn is in flight; cleared the moment it settles. Agent.stop()
-- calls this, which is what the Stop button drives.
local stopCurrent: (() -> ())? = nil
-- Running total for this session, the equivalent of the Session block in Claude
-- Code's /usage. Plan limits are a separate thing and come from the usage
-- endpoint (OAuth.fetchUsage); this is just what this session has spent.
local totals = { input = 0, output = 0 }
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

function Agent.Initialize(terminal: any, busyCallback: ((boolean) -> ())?)
	term = terminal
	onBusyChanged = busyCallback
end

function Agent.conversation(): { any }
	return conversation
end

function Agent.reset()
	conversation = {}
end

-- Adopts a saved conversation wholesale (Sessions). Takes the table rather than
-- copying it, so later turns append to the same list the caller holds.
function Agent.restore(messages: { any })
	conversation = messages
	-- This prefix was last written by whatever session saved it, so nothing here
	-- is cached under the current one. Clearing the stamp says so, which makes
	-- the first turn after a restore the free one to clear on.
	lastRequestAt = nil
end

function Agent.usage(): { input: number, output: number }
	return totals
end

function Agent.isBusy(): boolean
	return busy
end

local function setBusy(value: boolean)
	busy = value
	if not value then
		stopCurrent = nil
		-- The request is over, so anything still waiting on a result is never
		-- getting one — a cancel or an error mid-search. Stop the spinners rather
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

-- =============================================================================
-- Keeping the history bounded
-- =============================================================================
-- forModel() caps any single result and capTurn() caps one turn's batch of
-- them; nothing caps the sum across turns. `conversation` is append-only, so a
-- long session ends by hitting the context window and dying with no way back
-- from it. This is Claude Code's microcompact minus the half
-- we cannot have: it persists cleared output to disk and can restore it after a
-- compaction, and a plugin has nowhere to spill to. Cleared output here is
-- gone, which is why the stub says so — re-running the command is the recovery.
--
-- Two things this has to get right, or it makes matters worse than it found
-- them:
--
--   Stub the content, never remove the block. Every tool_result pairs with a
--   tool_use already in the history; drop one and every later request fails on
--   the same index for the rest of the session. Empty content is rejected
--   outright (see the "(no output)" guard below), so the stub is a non-empty
--   sentence — kept short, because it is paid once per cleared result and
--   because anything it replaces has to be LONGER than it or clearing costs
--   tokens instead of saving them. Claude Code's equivalent is shorter still
--   ("[Old tool result content cleared]") and can afford to say nothing useful,
--   since it persists the cleared output and can restore it. Ours is gone, so
--   the stub has to earn its length by naming the recovery.
--
--   Run it only when the prefix is being re-written anyway. Mutating a message
--   invalidates the cache from that index onward, and old results sit near the
--   FRONT of the history, so a pass re-writes almost the entire prefix at the 1h
--   write rate. Size it: at 50k tokens of history, clearing 20k costs 2.0x30k
--   now against 0.1x50k for the read it replaced, and returns 0.1x20k per later
--   turn — about 28 turns to break even, on a session that will re-cross the
--   trigger long before that. The saving scales with what is cleared; the cost
--   scales with the whole prefix, so no saving threshold can make a warm-cache
--   pass pay for itself. Hence cacheIsCold() below.
-- ponytail: tool results only. A session that grows on assistant text rather
-- than tool output — or one with five results and nothing older — is still
-- unbounded, because there is nothing here for this to clear. Upgrade path is
-- summarising compaction, which replaces spans of history with a paragraph
-- instead of only blanking results.
local KEEP_RECENT = 5
local CLEARED = "[old tool result cleared — re-run the command if needed]"
local TRIGGER_CHARS = 200000    -- ~50k tokens of history before this is worth looking at
local MIN_SAVING_CHARS = 80000  -- ~20k tokens; below this even a paid-for re-write is not worth it
local URGENT_CHARS = 600000     -- ~150k tokens; past here the window, not the cache, is the risk
local COLD_AFTER = 60 * 60      -- seconds; the full 1h TTL withMessageCache asks for, not a hair under

-- os.time() of the last request. nil means none has gone out, so there is no
-- cached prefix to protect — a restored session starts here too, since its
-- prefix was last written by whichever session saved it.
local lastRequestAt: number? = nil

-- Past COLD_AFTER the 1h TTL has expired, the whole prefix is re-written on the
-- next request whatever we do, and clearing first only shrinks what gets
-- re-written — so the pass is free. This is Claude Code's time-based
-- microcompact trigger (evaluateTimeBasedTrigger); it is the one part of that
-- mechanism a plugin can have, since the TTL we asked for is knowable
-- client-side while their other two free paths are not (cache_edits needs a
-- server-side context_management API, autocompact needs somewhere to spill).
--
-- The full hour, not a hair under. Their comment gives the rule: 60 minutes is
-- "the safe choice: the server's 1h cache TTL is guaranteed expired for all
-- users, so we never force a miss that wouldn't have happened." Anything short
-- of the TTL can still land on a live cache, which is the exact miss this gate
-- exists to avoid — erring early here does the damage it is meant to prevent,
-- while erring late costs one turn of carrying results that were free to carry.
--
-- Wall clock rather than a monotonic one, because the gap being measured is the
-- user leaving the widget docked, not CPU time. A clock stepped backwards reads
-- as warm and skips a pass; forwards, it buys one unnecessary re-write. Neither
-- is worth guarding.
local function cacheIsCold(): boolean
	return lastRequestAt == nil or os.time() - lastRequestAt >= COLD_AFTER
end

-- Deliberately an estimate, not a token count: it only decides whether to look
-- closer. tool_use inputs are tables and go uncounted, which biases it low —
-- the right direction for a trigger that costs a cache re-write to act on.
local function historyChars(messages: { any }): number
	local total = 0
	for _, message in ipairs(messages) do
		local content = message.content
		if type(content) == "string" then
			total += #content
		elseif type(content) == "table" then
			for _, block in ipairs(content) do
				if type(block) == "table" then
					if type(block.text) == "string" then total += #block.text end
					if type(block.content) == "string" then total += #block.content end
				end
			end
		end
	end
	return total
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
	-- enough to the window that the next few turns could fail outright — there
	-- the re-write is the cheaper of two bad options, because nothing else here
	-- reclaims anything.
	if not cold and chars < URGENT_CHARS then return 0 end

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
	-- exact position (`if (tokensSaved === 0) return null` — there is no saving
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

-- =============================================================================
-- One turn
-- =============================================================================
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

	local bubble = Console.createBubble()
	local text = ""        -- every text delta of the turn; what the history gets
	local bubbleText = ""  -- only the part belonging to the CURRENT bubble
	local finished = false

	-- A server tool runs mid-stream, so its console block lands below a bubble
	-- that is still being written to — and the text that comes AFTER the search
	-- then renders above the search that produced it. (Our own tools never do
	-- this: they are dispatched in onComplete, once the bubble is finished.) So a
	-- server tool ends the current bubble and the next text starts a new one
	-- below its block. Deferred rather than done on the spot, so consecutive
	-- searches do not leave a row of empty bubbles between them.
	local splitPending = false
	-- Adaptive thinking streams a thinking block whether or not there is a
	-- summary to go with it: a short thought summarises to nothing, and the
	-- deltas arrive as empty strings. The drawer was created on the FIRST delta
	-- whatever it held, so those turns put up a "▶ thinking" row that opened on
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

	local function finish()
		if finished then return true end
		finished = true
		return false
	end

	-- Forward-declared and assigned AFTER the call, so stopCurrent must not
	-- capture it by value. Registering the stop handler BEFORE the request also
	-- closes a real gap: OAuth.getAccessToken() yields on a token refresh, and
	-- during that window there was previously no handler at all — Stop did
	-- nothing, or worse, referenced a local that had not been assigned yet.
	local stream: any = nil
	local cancelRequested = false

	stopCurrent = function()
		if finish() then return end
		cancelRequested = true
		if stream then stream.cancel() end
		bubble.finishThinking()

		-- Leave the history in a shape the next request can build on. Partial
		-- text becomes a normal assistant message so roles still alternate; a
		-- partial tool_use is dropped, since it has no tool_result to pair with
		-- and Anthropic would reject the pair on the next turn.
		if text ~= "" then
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

	stream = Claude.streamMessage({
		model = Settings.model(),
		system = Settings.system(),
		messages = conversation,
		maxTokens = Settings.maxTokens(),
		effort = Settings.effort(),
		thinkingBudget = Settings.thinkingBudget(),
		tools = buildTools(),
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
			splitPending = true
			local call = Console.appendToolCall(name, {})
			-- Nothing can pair a result to a block with no id, so it must not be
			-- left spinning for one.
			if id then pendingCalls[id] = call else call.finish() end
		end,

		onServerToolUse = function(name: string, id: string?, input: any)
			splitPending = true
			-- Header goes up now, results are filled in when they arrive: the API
			-- runs these itself and sends the call and its result as two separate
			-- blocks, so waiting for both would leave the console silent for the
			-- whole search.
			local call = Console.appendToolCall(name, type(input) == "table" and input or {})
			-- No id means nothing can ever pair a result to this block, so it must
			-- not be left spinning for one.
			if id then pendingCalls[id] = call else call.finish() end
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
				warn("[Claude Code] " .. tostring(result.error))
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
			-- only it is scoped to the current bubble — result.text is every text
			-- block of the turn, including the ones already drawn in earlier
			-- bubbles above a search. A turn that only thought and called a tool
			-- has no text at all, and gets no empty render.
			if bubbleText ~= "" then
				bubble.setText(bubbleText)
			end

			-- Counted here rather than in the final-turn block below: a tool-use
			-- turn returns early, and its tokens are just as billed.
			if result.usage then
				totals.input += (result.usage.input_tokens or 0)
					+ (result.usage.cache_read_input_tokens or 0)
					+ (result.usage.cache_creation_input_tokens or 0)
				totals.output += result.usage.output_tokens or 0
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
					-- match what it generated — they cannot be reordered, edited, or
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
				elseif SERVER_RESULT_BLOCKS[block.type] and block.raw then
					-- Server tool results arrive complete and are replayed verbatim.
					-- Dropping one while keeping its server_tool_use would leave an
					-- unanswered call in the history. Matched by an explicit list,
					-- not "has a raw field": thinking blocks have one too, and their
					-- raw copy is the empty shell from content_block_start, before
					-- any delta filled it in.
					table.insert(assistantContent, block.raw)
				end
			end

			table.insert(conversation, {
				role = "assistant",
				-- "(empty)" here is for the wire, not the screen: an assistant
				-- message with empty content is rejected, and this branch only
				-- runs when the turn produced no blocks at all.
				content = #assistantContent > 0 and assistantContent or (result.text or "(empty)"),
			})

			-- Run the tools. Every tool_use needs a matching tool_result, including
			-- ones whose input failed to parse — an unanswered tool_use is a
			-- protocol error, so failures go back as error text.
			local toolResults: { any } = {}
			for _, block in ipairs(toolUses) do
				local toolResult: string
				-- The block onToolUseStart put up while the input was streaming.
				-- Claimed here so the cleanup in setBusy cannot finish a block this
				-- loop is about to write a result into.
				local call = block.id and pendingCalls[block.id] or nil
				if block.id then pendingCalls[block.id] = nil end
				if block.inputParsed then
					-- The arguments only exist now; the header has been up since the
					-- model started writing the call. The fallback covers a stream
					-- that somehow produced no start event — dispatch blocks this
					-- thread for as long as the tool takes, and catalog/run/web calls
					-- take seconds, so a spinner has to be saying which call the wait
					-- belongs to either way.
					if call then
						call.setInput(block.inputParsed)
					else
						call = Console.appendToolCall(block.name, block.inputParsed)
					end
					toolResult = Tools.dispatch(term, block.name, block.inputParsed)
					-- A tool_result whose content is "" is rejected outright, and on
					-- turn > 1 it cannot be rolled back: the tool_use is already in
					-- the history above, so every retry resends the same poisoned
					-- pair and fails identically — a dead session from one command
					-- that happened to print nothing. Reached by `cat` of an empty
					-- script, `diff` of two identical ones, bare `echo`, sort/uniq/tr
					-- with no stdin, and anything redirected to /dev/null. Guarded
					-- here rather than in each handler because "" is a correct result
					-- for /sh; it is only invalid on the wire.
					if toolResult == "" then toolResult = "(no output)" end
					call.setResult(toolResult)
				else
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
					-- overruns it — the Output window keeps the whole thing.
					warn(string.format("[Claude Code] %s: unparsed tool input (stop_reason: %s): %s",
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
				})
			end
			-- Capped HERE and not in Tools.dispatch: setResult() above has already
			-- handed the Console the whole thing, so the panel keeps the full
			-- output and only the history pays. After the loop rather than inside
			-- it, because the budget is a property of the batch — and cutting
			-- twice would leave a result carrying two truncation notes.
			capTurn(toolResults)

			-- pause_turn: a long-running server tool was interrupted mid-turn.
			-- Anthropic expects the paused assistant content sent straight back so
			-- it can carry on; there are no tool results to attach.
			if result.stopReason == "pause_turn" and #toolResults == 0 then
				task.spawn(function()
					task.wait(0.1)
					runTurn(turn + 1)
				end)
				return
			end

			if #toolResults > 0 then
				-- All results in ONE user message. Anthropic requires every
				-- tool_result for a turn to arrive together.
				table.insert(conversation, { role = "user", content = toolResults })
				task.spawn(function()
					task.wait(0.1)  -- let the UI paint before the next request
					runTurn(turn + 1)
				end)
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

		onError = function(message: string)
			if finish() then return end
			warn("[Claude Code] " .. message)
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

-- =============================================================================
-- Entry point
-- =============================================================================
function Agent.send(text: string, isLoggedIn: () -> boolean)
	if busy then return end
	if not isLoggedIn() then
		Console.appendLine("Not logged in. Use /login.", "error")
		return
	end

	Console.appendLine(text, "user")
	table.insert(conversation, { role = "user", content = text })
	setBusy(true)
	runTurn(1)
end

-- =============================================================================
-- Self-test
-- =============================================================================
-- Both of these shape what goes on the wire, and both fail in ways that only
-- show up as a dead session: a cut that lands mid-codepoint makes JSONEncode
-- reject the request, and a cleared tool_result that loses its pairing or comes
-- back empty poisons every later turn.
function Agent.selfTest(): (boolean, string?)
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
	-- bytes so the thing being tested — a cut landing between them — is on the
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
	-- half ends in a newline, then forModel adds its own before the marker — so a
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
	-- BETWEEN TRIGGER_CHARS and URGENT_CHARS, so a hand-typed size stops
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
	-- gate exists to prevent — and it is silent, so only a test catches it.
	lastRequestAt = os.time()
	if clearOldToolResults(pairedHistory(12, coldSize)) ~= 0 then
		return false, "clearOldToolResults re-wrote a warm cached prefix to save a fraction of it"
	end

	-- Warm, but past URGENT_CHARS: the window is now the risk rather than the
	-- cache, and nothing else here reclaims anything, so it has to clear anyway.
	if clearOldToolResults(pairedHistory(12, URGENT_CHARS // 10)) <= 0 then
		return false, "clearOldToolResults left a history near the context window uncleared"
	end

	lastRequestAt = savedStamp
	return true
end

return Agent
