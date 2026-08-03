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

function Agent.isBusy(): boolean
	return busy
end

local function setBusy(value: boolean)
	busy = value
	if not value then stopCurrent = nil end
	if onBusyChanged then onBusyChanged(value) end
end

-- Cancels the in-flight turn. Safe to call when idle.
function Agent.stop()
	local stop = stopCurrent
	if stop then stop() end
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

	local bubble = Console.createBubble()
	local text = ""
	local finished = false

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
			bubble.setText(text)
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
			-- The bubble creates its thinking block on demand, above the answer.
			bubble.thinking().append(delta)
		end,

		onText = function(delta: string)
			text ..= delta
			bubble.setText(text)
		end,

		onServerToolUse = function(name: string, input: any)
			local query = type(input) == "table" and input.query or nil
			Console.appendLine(string.format("[%s: %s]", name, tostring(query or "…")), "cmd")
		end,

		onServerToolResult = function(name: string, count: number)
			Console.appendLine(string.format("  %d results", count), "info")
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

			bubble.setText(result.text or "(empty)")

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
						input = block.inputParsed or {},
					})
					table.insert(toolUses, block)
				elseif block.type == "server_tool_use" then
					-- Anthropic ran this one. We replay it but never dispatch it,
					-- so it is deliberately NOT added to toolUses.
					table.insert(assistantContent, {
						type = "server_tool_use",
						id = block.id,
						name = block.name,
						input = block.inputParsed or {},
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
				content = #assistantContent > 0 and assistantContent or (result.text or "(empty)"),
			})

			-- Run the tools. Every tool_use needs a matching tool_result, including
			-- ones whose input failed to parse — an unanswered tool_use is a
			-- protocol error, so failures go back as error text.
			local toolResults: { any } = {}
			for _, block in ipairs(toolUses) do
				local toolResult: string
				if block.inputParsed then
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
					Console.appendToolCall(block.name, block.inputParsed, toolResult)
				else
					toolResult = "error: failed to parse tool input"
					Console.appendLine("[" .. tostring(block.name) .. ": parse error]", "error")
				end
				table.insert(toolResults, {
					type = "tool_result",
					tool_use_id = block.id,
					content = toolResult,
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
				Console.appendLine(string.format("  %d in / %d out",
					result.usage.input_tokens or 0, result.usage.output_tokens or 0), "system")
			end
			setBusy(false)
		end,

		onError = function(message: string)
			if finish() then return end
			warn("[Claude Code] " .. message)
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

return Agent
