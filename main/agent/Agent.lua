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

local MAX_TURNS = 40  -- hard stop on the tool-use loop

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
-- instead of nothing: an object either way, and it shows what was cut off.
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
local function forModel(result: string): string
	if #result <= MODEL_RESULT_CHARS then return result end
	local kept = safeCut(result, MODEL_RESULT_CHARS)
	return string.format(
		"%s\n... [%d characters truncated] ...\n" ..
		"Re-run narrowed to see the rest: `head -n`, `tail -n`, `sed -n '10,40p'`, " ..
		"or `grep` for what you are actually looking for.",
		kept, #result - #kept)
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
-- server_tool_use id -> the console block waiting for its result. Keyed by id
-- rather than "the last one", because a turn can run several searches.
--
-- Deliberately NOT per-turn. On stop_reason "pause_turn" Anthropic interrupts a
-- long-running search, so the server_tool_use lands in one stream and its
-- web_search_tool_result in the NEXT one, after runTurn has recursed. A per-turn
-- table lost the pairing across that boundary: the first block spun forever and
-- the result arrived as a second, argument-less [web_search] below it. Parallel
-- searches hit it most, being the slowest turns and the likeliest to be paused.
local serverCalls: { [string]: any } = {}

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
		for id, call in pairs(serverCalls) do
			call.finish()
			serverCalls[id] = nil
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
-- forModel() caps any single result; nothing caps the sum. `conversation` is
-- append-only, so a long session ends by hitting the context window and dying
-- with no way back from it. This is Claude Code's microcompact minus the half
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
--   Run it rarely. Mutating a message invalidates the cache from that index
--   onward, so every pass costs one full re-write of the prefix. Claude Code
--   only fires when it would save at least 20k tokens; these are the same two
--   thresholds at roughly 4 characters per token.
-- ponytail: tool results only, and no thrash guard. Two ceilings follow from
-- that. A session that grows on assistant text rather than tool output — or one
-- with five results and nothing older — is still unbounded, because there is
-- nothing here for this to clear. And a heavy session can re-cross the trigger
-- every few turns, paying a prefix re-write each time; Claude Code carries an
-- explicit circuit breaker for exactly that ("Autocompact is thrashing … 3
-- times in a row"). Upgrade path for both is summarising compaction, which
-- replaces spans of history with a paragraph instead of only blanking results.
--
-- The trigger is also on the eager side: 200k characters is ~50k tokens, about
-- a quarter of the window, so this starts paying re-writes well before the
-- session is in any danger. Raise it if the per-turn `N new to cache` figure
-- looks worse than the read it saves.
local KEEP_RECENT = 5
local CLEARED = "[old tool result cleared — re-run the command if needed]"
local TRIGGER_CHARS = 200000    -- ~50k tokens of history before this is worth doing at all
local MIN_SAVING_CHARS = 80000  -- ~20k tokens; under this the cache re-write costs more than it saves

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
	if historyChars(messages) < TRIGGER_CHARS then return 0 end

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
	if saving < MIN_SAVING_CHARS then return 0 end

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
	if turn > MAX_TURNS then
		Console.appendLine("Tool loop exceeded " .. MAX_TURNS .. " turns — stopping.", "error")
		setBusy(false)
		return
	end

	-- Before the request rather than after it: the whole point is to shrink what
	-- this turn sends. Runs on every turn including mid-tool-loop, because a
	-- single 40-turn sweep is exactly the thing that can fill the window without
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
	local function splitBubble()
		if not splitPending then return end
		splitPending = false
		bubble.finishThinking()
		bubble = Console.createBubble()
		bubbleText = ""
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

		onServerToolUse = function(name: string, id: string?, input: any)
			splitPending = true
			-- Header goes up now, results are filled in when they arrive: the API
			-- runs these itself and sends the call and its result as two separate
			-- blocks, so waiting for both would leave the console silent for the
			-- whole search.
			local call = Console.appendToolCall(name, type(input) == "table" and input or {})
			-- No id means nothing can ever pair a result to this block, so it must
			-- not be left spinning for one.
			if id then serverCalls[id] = call else call.finish() end
		end,

		onServerToolResult = function(name: string, toolUseId: string?, content: any)
			local body = formatServerResult(content)
			local call = if toolUseId then serverCalls[toolUseId] else nil
			if call then
				serverCalls[toolUseId :: string] = nil
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
				if block.type == "text" and block.text ~= "" then
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
				if block.inputParsed then
					-- Header goes up before the tool runs, not after: dispatch blocks
					-- this thread for as long as the tool takes, and catalog/run/web
					-- calls take seconds. The spinner is the only thing saying which
					-- call the wait belongs to.
					local call = Console.appendToolCall(block.name, block.inputParsed)
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
					Console.appendToolCall(
						tostring(block.name) .. " parse error",
						{ raw_input = tostring(block.input) },
						toolResult,
						true)
				end
				table.insert(toolResults, {
					type = "tool_result",
					tool_use_id = block.id,
					-- Capped HERE and not in Tools.dispatch: setResult() above has
					-- already handed the Console the whole thing, so the panel keeps
					-- the full output and only the history pays.
					content = forModel(toolResult),
				})
			end

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

	-- Clearing: 12 paired calls, well over the trigger.
	local big = string.rep("x", 20000)
	local messages: { any } = {}
	for i = 1, 12 do
		table.insert(messages, { role = "assistant", content = {
			{ type = "tool_use", id = "t" .. i, name = "bash", input = { command = "ls" } },
		} })
		table.insert(messages, { role = "user", content = {
			{ type = "tool_result", tool_use_id = "t" .. i, content = big },
		} })
	end

	if clearOldToolResults(messages) <= 0 then
		return false, "clearOldToolResults did nothing to an oversized history"
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

	return true
end

return Agent
