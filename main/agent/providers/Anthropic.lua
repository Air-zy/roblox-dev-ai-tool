--!optimize 2
-- Anthropic.luau: Messages API client. Bearer token comes from AnthropicAuth.
--
-- Anthropic routes OAuth traffic to different rate-limit pools depending on
-- whether a request looks like the official CLI. Four signals, we send three:
-- the anthropic-beta header, `x-app: cli`, and an exact identity string as
-- system[0]. The fourth is a claude-cli user-agent, and Roblox locks that
-- header, so whether three is enough has never been measured.
--
-- That identity string is a billing artefact, not a description of this
-- program. It tells the model it is the CLI, which ships a Bash tool over a
-- real filesystem, so Settings.system() has to say there is no disk here.
--
-- Public API:
--   Initialize(auth)
--   streamMessage({ model, system, messages, maxTokens, tools }, callbacks) -> handle
--   webSearchTool(maxUses)
--   MODELS, DEFAULT_MODEL
--
-- The old non-streaming sendMessage/sendWithTools pair is gone. Agent drives the
-- tool loop over streamMessage, and two implementations of one protocol is how
-- the sendToClaude/sendToClaude_continue drift happened.

local HttpService = game:GetService("HttpService")
local warn = warn

local OAuth: any = nil  -- set via Initialize

-- Constants
local MESSAGES_URL = "https://api.anthropic.com/v1/messages"
local ANTHROPIC_VERSION = "2023-06-01"

-- Beta header values that mark the request as Claude Code traffic. Both entries
-- are load-bearing: oauth-2025-04-20 is required whenever the credential is a
-- bearer token rather than an api key, and claude-code-20250219 is the traffic
-- marker itself.
--
-- Two more used to ride along here and were removed as dead:
--   interleaved-thinking-2025-05-14, adaptive thinking turns interleaved
--     thinking on by itself, and applyReasoning asks for adaptive on every
--     model that supports it.
--   fine-grained-tool-streaming-2025-05-14, no longer a beta at all. The
--     switch is `eager_input_streaming` on the TOOL DEFINITION; the header
--     does nothing. Not set here either, deliberately: onToolUseStart already
--     puts the call header up at content_block_start, before any argument has
--     streamed, and setInput runs once with the finished input. Nothing renders
--     partial arguments, so there is currently nothing for it to improve.
local ANTHROPIC_BETA = "claude-code-20250219,oauth-2025-04-20"

-- The identity block Anthropic checks for. Must be the FIRST system block.
local CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."

-- Per-model thinking + effort support.
--   thinking = "adaptive": thinking:{type:"adaptive"}; the model decides when and
--     how deeply to think, steered by effort. thinking:{type:"enabled"} with
--     budget_tokens returns a 400 on these models.
--   thinking = "budget": legacy extended thinking. budget_tokens is the only
--     control; output_config.effort is NOT supported and must be omitted.
-- Unknown models default to adaptive, matching every current Claude release.
local MODEL_CAPS: { [string]: { thinking: string, effort: boolean } } = {
	["claude-opus-5"]             = { thinking = "adaptive", effort = true },
	["claude-sonnet-5"]           = { thinking = "adaptive", effort = true },
	["claude-haiku-4-5"]          = { thinking = "budget",   effort = false },
}
local DEFAULT_CAPS = { thinking = "adaptive", effort = true }

local function capsFor(model: string): { thinking: string, effort: boolean }
	return MODEL_CAPS[model] or DEFAULT_CAPS
end

-- Carried as parts, not as one string the callers take apart again. `label` is
-- the whole line for anything with room for it; `name` and `hint` exist because
-- the compact rows want them separately and used to recover them with a pair of
-- regexes in main.luau — one of which had to strip the vendor word, which meant
-- naming a vendor in a file that is not allowed to. Composing here is free;
-- parsing it back cost a heuristic that guessed wrong on a two-word vendor.
local MODELS = {
	{ id = "claude-sonnet-5",  label = "Claude Sonnet 5 (recommended)", name = "Sonnet 5",  hint = "recommended" },
	{ id = "claude-opus-5",    label = "Claude Opus 5 (Max only)",      name = "Opus 5",    hint = "Max only" },
	{ id = "claude-haiku-4-5", label = "Claude Haiku 4.5 (fastest)",    name = "Haiku 4.5", hint = "fastest" },
}
local DEFAULT_MODEL = "claude-sonnet-5"

-- Anthropic-executed ("server") tool: the API runs the searches itself and
-- feeds Claude the results, so there is nothing for our dispatcher to do. Note
-- it is billed per search on top of tokens.
-- Deliberately the 20250305 version and not web_search_20260209. The newer one
-- filters results by running code under the hood, which surfaces code_execution
-- blocks the model then tries to call web_search from, hits a limit inside, and
-- narrates its way out of. Better search was not worth a confused agent.
local function webSearchTool(maxUses: number): any
	return {
		type = "web_search_20250305",
		name = "web_search",
		max_uses = maxUses,
	}
end

local function Initialize(oauthModule: any)
	OAuth = oauthModule
end

-- Builds the thinking/effort part of the body.
local function applyReasoning(bodyTable: { [string]: any }, model: string, effort: string?, thinkingBudget: number?)
	local caps = capsFor(model)

	if caps.effort and effort and effort ~= "" then
		-- Request-level, no beta header on current models. "high" is the API
		-- default, so passing it is the same as omitting it.
		bodyTable.output_config = { effort = effort }
	end

	if caps.thinking == "adaptive" then
		-- `display` defaults to "omitted" on current models, and omitted does not
		-- mean "no thinking blocks", it means the blocks arrive with an EMPTY
		-- thinking field. The console's thinking drawer was therefore opening on
		-- nothing at all. "summarized" is what actually puts words in it. Thinking
		-- happens and is billed the same either way; this only controls whether
		-- you get to read it.
		bodyTable.thinking = { type = "adaptive", display = "summarized" }
	elseif thinkingBudget and thinkingBudget > 0 then
		bodyTable.thinking = { type = "enabled", budget_tokens = thinkingBudget }
		-- Thinking tokens count against max_tokens, so the budget has to leave
		-- room for the actual answer.
		if (bodyTable.max_tokens :: number) <= thinkingBudget then
			bodyTable.max_tokens = thinkingBudget + 4096
		end
	end
end

-- The moving cache breakpoint on the conversation.
--
-- Returns a COPY. The conversation table is the SAME table across turns
-- Agent.luau never rebuilds it, only appends, and it is also what Sessions
-- persists and replays, so writing anything into it here leaks request-shaping
-- into stored history. That is not hypothetical: this used to REPLACE a user
-- message's string content with a one-element block array so the breakpoint had
-- a block to sit on, which turned every user message in the history into a
-- table. Sessions.replay draws user turns from string content, so a restored
-- session showed the assistant's side and none of yours, and titleOf fell
-- through to a date for the same reason.
--
-- Copying also removes the need to strip old breakpoints. Anthropic caps a
-- request at 4 cache_control blocks (system + tools + messages combined); a tag
-- written into the live table survived into later turns, so turn 3 sent three
-- of them and every call failed with "A maximum of 4 blocks with cache_control
-- may be provided." A fresh copy per request cannot accumulate.
--
-- Shallow throughout: only the last message, its block list and its last block
-- are cloned, so this is three small tables however long the conversation is.
local function withMessageCache(messages: { any }): { any }
	-- 1h, the same TTL the system and tool breakpoints use.
	--
	-- This used to be the default 5m, on the reasoning that a breakpoint which
	-- moves and grows every turn would have its write cost doubled. That is not
	-- what happens while the cache is warm: the lookup is a longest-prefix
	-- match, so turn N+1 reads turn N's entry and writes only the delta. The
	-- 2x lands on one turn's new messages; a 5m expiry costs a 1.25x rewrite of
	-- the entire history. This is a plugin people leave docked while they read
	-- code, so the gaps this UI is made of are exactly the ones that expire it.
	--
	-- ponytail: no overage gating. Claude Code drops to 5m for a subscriber who
	-- is into overage, and latches the choice for the whole session because
	-- flipping TTL mid-session busts the server-side cache. If plan usage ever
	-- drives this, latch it once at session start, never per turn.
	local CACHE = { type = "ephemeral", ttl = "1h" }

	local out = table.clone(messages)
	local lastMessage = out[#out]
	local content = lastMessage and lastMessage.content
	if type(content) == "table" and #content > 0 and type(content[#content]) == "table" then
		local blocks = table.clone(content)
		local tail = table.clone(blocks[#blocks])
		tail.cache_control = CACHE
		blocks[#blocks] = tail
		local copy = table.clone(lastMessage)
		copy.content = blocks
		out[#out] = copy
	elseif type(content) == "string" and content ~= "" then
		local copy = table.clone(lastMessage)
		copy.content = { { type = "text", text = content, cache_control = CACHE } }
		out[#out] = copy
	end
	return out
end

-- streamMessage: streaming via CreateWebStreamClient (SSE)
-- Sends a streaming request. Callbacks fire as deltas arrive:
--   onText(text), called for each text_delta chunk
--   onThinking(text), called for each thinking_delta chunk
--   onComplete(result), called when stream ends; result has full text, thinking, usage, stopReason
--   onError(message), called on error (network or API)
--
-- `onText` fires incrementally, you get a few characters at a time.
-- The UI should append to the current assistant bubble and auto-scroll.
--
-- Returns immediately (streaming happens in the background). The caller should
-- track completion via onComplete/onError.
local function streamMessage(args: {
	model: string?,
	system: string?,
	messages: { any },
	maxTokens: number?,
	effort: string?,
	thinkingBudget: number?,
	tools: { any }?,
	}, callbacks: {
		onText: ((string) -> ())?,
		onThinking: ((string) -> ())?,
		onToolUseStart: ((string?, string) -> ())?,  -- (blockId, toolName), before any input
		onServerToolUse: ((string, string?, any) -> ())?,  -- (toolName, blockId, parsedInput)
		onServerToolResult: ((string, string?, any) -> ())?, -- (toolName, toolUseId, rawContent)
		onComplete: ((any) -> ())?,
		onError: ((string, string?) -> ())?,
	}): { cancelled: boolean, cancel: () -> () }
	local function noopHandle()
		return { cancelled = true, cancel = function() end }
	end

	if not OAuth then
		if callbacks.onError then callbacks.onError("Claude module not initialized.") end
		return noopHandle()
	end
	if not args or type(args.messages) ~= "table" or #args.messages == 0 then
		if callbacks.onError then callbacks.onError("messages array is required and must be non-empty.") end
		return noopHandle()
	end

	local accessToken, tokenErr = OAuth.getAccessToken()
	if not accessToken then
		if callbacks.onError then callbacks.onError("Auth: " .. tostring(tokenErr)) end
		return noopHandle()
	end

	local model = args.model or DEFAULT_MODEL
	local maxTokens = args.maxTokens or 4096

	local systemBlocks = {
		{ type = "text", text = CLAUDE_CODE_IDENTITY },
	}
	if args.system and args.system ~= "" then
		table.insert(systemBlocks, { type = "text", text = args.system })
	end
	-- The system prompt and the tool definitions are the same on every turn of
	-- a conversation, so marking the last block of each as a cache breakpoint
	-- means Anthropic can skip reprocessing them. Two things ride on this: the
	-- token bill, and time-to-first-byte on a long thread, a full reprocess of
	-- a large uncached prompt is exactly the silence that trips Roblox's
	-- WebStreamClient InactivityTimeout before any byte comes back.
	--
	-- 1h rather than the default 5m, because this is a plugin someone leaves
	-- docked while they read code and think. The default TTL expires in exactly
	-- the gaps this UI is made of, and every expiry reprocesses system + tools
	-- from cold. A 1h write costs 2x instead of 1.25x, but this prefix is small
	-- and static, the whole thing is paid once an hour. The conversation
	-- breakpoint below is 1h for the same reason; see withMessageCache, which
	-- is where the argument for the other answer used to live.
	--
	-- That 2x may never actually be charged, and the breakpoint stays anyway.
	-- There is a MINIMUM cacheable prefix and it varies by model, 512 tokens on
	-- opus-5, 1024 on sonnet-5, 4096 on haiku-4-5, under which nothing is
	-- written and nothing is billed. Identity plus the one-line default system
	-- prompt plus seven short tool descriptions is plausibly under all three, so
	-- on a cold turn expect cache_creation_input_tokens = 0 rather than a write.
	-- Costing nothing is exactly why it stays: the moment a user writes a longer
	-- system prompt the prefix crosses the line and this starts paying.
	--
	-- No beta header is needed for `ttl`, it is GA, not gated.
	(systemBlocks[#systemBlocks] :: any).cache_control = { type = "ephemeral", ttl = "1h" }

	local bodyTable: { [string]: any } = {
		model = model,
		max_tokens = maxTokens,
		-- messages is set below, through withMessageCache. Deliberately absent
		-- here: it was assigned raw and overwritten thirty lines later, which
		-- read as though the untagged conversation went on the wire.
		stream = true,  -- CRITICAL: enable streaming
		system = systemBlocks,
	}

	applyReasoning(bodyTable, model, args.effort, args.thinkingBudget)

	if args.tools and #args.tools > 0 then
		-- Writes into the caller's table. Agent.buildTools() hands over freshly
		-- built definitions precisely so the tag cannot accumulate on a shared
		-- tool definition across turns.
		local lastTool = args.tools[#args.tools] :: any
		lastTool.cache_control = { type = "ephemeral", ttl = "1h" }
		bodyTable.tools = args.tools
		-- Parallel tool use left ON. Agent.runTurn already walks every tool_use
		-- block and returns all the results in ONE user message, which is the
		-- shape the API requires, so the loop was always parallel-safe and
		-- disabling it only cost turns. Turns are the expensive unit here: each
		-- one resends the whole conversation, and a `ls` + `cat` + `grep` sweep
		-- that used to take three turns now takes one.
		bodyTable.tool_choice = { type = "auto" }
	end

	-- The conversation itself is the part that grows every turn. Marking the
	-- last block of the last message means everything before it, the whole
	-- prior history, is a cache read on the next call, not a reprocess. This
	-- is the breakpoint that actually matters as the tool loop climbs; the
	-- system and tools breakpoints above are small and static by comparison.
	bodyTable.messages = withMessageCache(args.messages)

	local bodyStr = HttpService:JSONEncode(bodyTable)

	-- Accumulators for the final result
	local textParts = {}
	local thinkingParts = {}
	local contentBlocks: { any } = {}  -- keyed by SSE index; MAY BE SPARSE
	local blockCount = 0               -- highest index seen, so nothing is missed
	local usage: any = nil
	local stopReason: string? = nil

	-- Forward-declare `stream` so processSSEEvents can reference it as an upvalue.
	-- Without this, processSSEEvents would capture the GLOBAL `stream` (nil), causing
	-- "attempt to index nil with 'Close'" when we try to close the stream.
	local stream: any = nil

	-- Returned to the caller so a Stop button has something to call. Cancelling
	-- closes the socket and latches, so no late SSE chunk can fire a callback
	-- after the UI has already been finalised.
	local handle = { cancelled = false, cancel = function() end }
	handle.cancel = function()
		if handle.cancelled then return end
		handle.cancelled = true
		pcall(function()
			if stream then stream:Close() end
		end)
	end

	-- Create the stream client using RawStream (not SSE) because:
	-- - The SSE client type validates that the RESPONSE Content-Type is
	--   text/event-stream. If Anthropic returns an error (400/429/etc.), the
	--   response body is application/json, and Roblox's SSE client rejects it
	--   with "Invalid Content-Type header for SSE client", hiding the actual
	--   error message from us.
	-- - RawStream doesn't validate Content-Type, so we can read error bodies.
	-- - Anthropic still sends SSE-formatted data for successful streams, so
	--   our SSE parsing logic works the same.
	-- We buffer received chunks and split on blank lines (\n\n) to get
	-- complete SSE events, since RawStream doesn't guarantee message boundaries.
	local sseBuffer = ""
	local function processSSEEvents(data: string)
		if handle.cancelled then return end
		sseBuffer = sseBuffer .. data
		-- SSE events are separated by blank lines (\n\n)
		-- Split and process all complete events, keep the remainder in the buffer
		while true do
			local eventEnd = sseBuffer:find("\n\n", 1, true)
			if not eventEnd then break end
			local eventStr = sseBuffer:sub(1, eventEnd - 1)
			sseBuffer = sseBuffer:sub(eventEnd + 2)

			-- Parse the event: look for "event:" and "data:" lines
			local currentEvent: string? = nil
			local dataLine: string? = nil
			for line in eventStr:gmatch("[^\r\n]+") do
				local evMatch = line:match("^event:%s*(.+)$")
				local dtMatch = line:match("^data:%s*(.+)$")
				if evMatch then
					currentEvent = evMatch
				elseif dtMatch then
					dataLine = dtMatch
				end
			end

			if currentEvent and dataLine then
				local parsed
				local parseOk = pcall(function()
					parsed = HttpService:JSONDecode(dataLine :: string)
				end)
				if not parseOk then
					continue
				end
				local evt = parsed :: any

				if currentEvent == "message_start" then
					-- Initial message object (empty content). Its usage carries
					-- input_tokens and the cache counts; message_delta repeats them
					-- cumulatively, so reading only the latter is not a loss.

				elseif currentEvent == "content_block_start" then
					local idx = evt.index
					local block = evt.content_block
					-- `raw` keeps the block exactly as the API sent it. Server tool
					-- results (web_search_tool_result) arrive COMPLETE here rather
					-- than as deltas, and they must be replayed verbatim on the next
					-- turn or the conversation loses its search grounding.
					blockCount = math.max(blockCount, idx + 1)
					contentBlocks[idx + 1] = {
						type = block.type,
						raw = block,
						text = "",
						thinking = "",
						input = "",
						name = block.name,
						id = block.id,
						citations = nil,
					}
					-- The name and id are final here; only the arguments are still
					-- coming. Announcing the call now is the difference between a
					-- header that appears as the model starts writing it and one
					-- that appears when the whole message has finished, seconds
					-- apart for a `write`, whose input IS the file.
					if block.type == "tool_use" and callbacks.onToolUseStart then
						callbacks.onToolUseStart(block.id, block.name or "unknown")
					end
					if block.type == "web_search_tool_result" and callbacks.onServerToolResult then
						-- Handed over raw: the caller pairs it with the server_tool_use
						-- it answers via tool_use_id, and decides what of it to show.
						callbacks.onServerToolResult("web_search", block.tool_use_id, block.content)
					end

				elseif currentEvent == "content_block_delta" then
					local idx = evt.index
					local delta = evt.delta
					local block = contentBlocks[idx + 1]
					if not block then
						block = { type = "text", text = "", thinking = "", input = "" }
						contentBlocks[idx + 1] = block
						blockCount = math.max(blockCount, idx + 1)
					end

					if delta.type == "text_delta" then
						block.text = block.text .. delta.text
						if callbacks.onText then callbacks.onText(delta.text) end
					elseif delta.type == "thinking_delta" then
						block.thinking = block.thinking .. delta.thinking
						if callbacks.onThinking then callbacks.onThinking(delta.thinking) end
					elseif delta.type == "signature_delta" then
						-- Exactly one per thinking block, immediately before its
						-- content_block_stop: it arrives under display "omitted" too,
						-- where no thinking_delta ever does. The signature is what the
						-- server decrypts to rebuild the real reasoning when the block
						-- is replayed, so a thinking block without it cannot be sent
						-- back: Anthropic rejects a missing or altered signature.
						block.signature = delta.signature
					elseif delta.type == "input_json_delta" then
						block.input = block.input .. delta.partial_json
					elseif delta.type == "citations_delta" then
						-- Cited text blocks carry their sources alongside the text;
						-- dropping them on replay loses the grounding for later turns.
						block.citations = block.citations or {}
						table.insert(block.citations, delta.citation)
					end

				elseif currentEvent == "content_block_stop" then
					local idx = evt.index
					local block = contentBlocks[idx + 1]
					-- Parse the accumulated tool input UNCONDITIONALLY. This used to be
					-- gated behind `callbacks.onToolUseStart`, which meant any caller that
					-- omitted that callback got block.inputParsed = nil, and the caller's
					-- `inputParsed or {}` fallback encoded as `[]`. Anthropic then rejects
					-- the next turn with "tool_use.input: Input should be an object".
					-- Parsing is stream state, not presentation; it must not depend on
					-- whether anyone is listening.
					-- server_tool_use streams its input exactly like tool_use, so it
					-- needs the same parse, even though WE never execute it.
					if block and (block.type == "tool_use" or block.type == "server_tool_use") then
						local inputParsed
						pcall(function()
							-- JSONDecode("") throws; a no-arg tool call never emits any
							-- input_json_delta, so `input` stays "".
							inputParsed = HttpService:JSONDecode(block.input ~= "" and block.input or "{}")
						end)
						-- nil on failure, and it stays nil: the caller uses it to decide
						-- whether the tool may be dispatched at all. What must NOT reach
						-- the wire is an empty table, which Roblox encodes as `[]`, see
						-- Agent.toolInput, which owns that fallback. block.input keeps the
						-- raw accumulated JSON for it, so do not stop retaining it.
						block.inputParsed = inputParsed
						-- Our own tool_use blocks were already announced at
						-- content_block_start; server ones are announced here
						-- instead, because the API runs them the moment they
						-- complete and their arguments are one short query.
						if block.type == "server_tool_use" and callbacks.onServerToolUse then
							callbacks.onServerToolUse(block.name or "unknown", block.id, inputParsed)
						end
					end

				elseif currentEvent == "message_delta" then
					if evt.delta and evt.delta.stop_reason then
						stopReason = evt.delta.stop_reason
					end
					if evt.usage then
						usage = evt.usage
					end

				elseif currentEvent == "message_stop" then
					-- contentBlocks is keyed by SSE index, so any index that never got
					-- a content_block_start or a delta leaves a hole, and ipairs()
					-- stops at the first hole, silently dropping every block after it.
					-- A dropped tool_use gets no tool_result, which desyncs the
					-- tool_use/tool_result pairing on the next turn. Compact once,
					-- here, so neither this loop nor the caller's can truncate.
					local dense: { any } = {}
					for i = 1, blockCount do
						local b = contentBlocks[i]
						if b then dense[#dense + 1] = b end
					end

					for _, b in ipairs(dense) do
						if b.type == "text" and b.text ~= "" then
							table.insert(textParts, b.text)
						elseif b.type == "thinking" and b.thinking ~= "" then
							table.insert(thinkingParts, b.thinking)
						end
					end

					if callbacks.onComplete then
						callbacks.onComplete({
							ok = true,
							text = #textParts > 0 and table.concat(textParts, "\n") or nil,
							thinking = #thinkingParts > 0 and table.concat(thinkingParts, "\n\n") or nil,
							usage = usage,
							stopReason = stopReason,
							contentBlocks = dense,
						})
					end
					stream:Close()

				elseif currentEvent == "error" then
					if callbacks.onError then
						local errMsg = "stream error"
						if evt.error and evt.error.message then
							errMsg = tostring(evt.error.message)
						end
						callbacks.onError(errMsg)
					end
					stream:Close()
				end
			end
		end
	end

	local client
	local ok, err = pcall(function()
		client = HttpService:CreateWebStreamClient(Enum.WebStreamClientType.RawStream, {
			Url = MESSAGES_URL,
			Method = "POST",
			Headers = {
				["Authorization"] = "Bearer " .. (accessToken :: string),
				["anthropic-version"] = ANTHROPIC_VERSION,
				["anthropic-beta"] = ANTHROPIC_BETA,
				["x-app"] = "cli",
				["content-type"] = "application/json",
				["accept"] = "text/event-stream",
			},
			Body = bodyStr,
		})
	end)

	if not ok or not client then
		if callbacks.onError then callbacks.onError("Failed to create stream client: " .. tostring(err)) end
		return noopHandle()
	end

	-- Assign to the forward-declared `stream` local (so processSSEEvents can see it)
	stream = client

	stream.Opened:Connect(function(statusCode: number, headers: string)
		if statusCode ~= 200 then
			-- Non-200 status, the error body will come through MessageReceived
			-- (since we're using RawStream, not SSE which would reject it)
			-- We'll parse the error from the body in MessageReceived.
		end
	end)

	stream.MessageReceived:Connect(function(message: string)
		if handle.cancelled then return end
		-- Try to parse as SSE events first (normal streaming response)
		-- If the response is an error (JSON, not SSE format), processSSEEvents
		-- won't find any valid events, and we'll check if it's a JSON error.
		local hadEvents = message:find("event:", 1, true) ~= nil
		if hadEvents then
			processSSEEvents(message)
		else
			-- Might be a JSON error response (non-SSE)
			local parsed
			local parseOk = pcall(function()
				parsed = HttpService:JSONDecode(message)
			end)
			if parseOk and type(parsed) == "table" and (parsed :: any).error then
				local e = (parsed :: any).error
				local msg = "HTTP error: " .. tostring(e.type or "") .. " — " .. tostring(e.message or "")
				warn("[Claude Code] " .. msg)
				warn("[Claude Code] Response body: " .. message)
				if callbacks.onError then callbacks.onError(msg) end
				stream:Close()
			else
				-- Could be a partial SSE event, buffer it
				processSSEEvents(message)
			end
		end
	end)

	stream.Error:Connect(function(statusCode: number, errorMessage: string)
		if handle.cancelled then return end
		handle.cancelled = true  -- latch first: a late MessageReceived must not race this
		warn("[Claude Code] Stream error (HTTP " .. tostring(statusCode) .. "): " .. tostring(errorMessage))
		if callbacks.onError then
			-- textParts is only filled in at message_stop, which an error mid-
			-- stream never reaches, so it is empty here even when real text
			-- already arrived. Read live from contentBlocks instead, the same
			-- accumulator onText has been writing into all along. Indexed by
			-- blockCount rather than ipairs for the same reason message_stop is:
			-- a hole would cut the partial text short.
			local partial: { string } = {}
			for i = 1, blockCount do
				local block = contentBlocks[i]
				if block and block.type == "text" and block.text ~= "" then
					table.insert(partial, block.text)
				end
			end
			-- Second argument is that partial text, so a caller (Agent.stopCurrent
			-- already does the equivalent for the Stop-button path) can keep a
			-- mostly-finished answer instead of discarding it on what is usually
			-- a transient stall, not a real failure.
			callbacks.onError(
				"Stream error (HTTP " .. tostring(statusCode) .. "): " .. tostring(errorMessage),
				#partial > 0 and table.concat(partial, "\n") or nil)
		end
		-- Only six WebStreamClients may exist at once. Every other exit path
		-- already closes; this one silently didn't, so after six timeouts in a
		-- session CreateWebStreamClient starts failing outright -- a completely
		-- different-looking symptom with this same root cause.
		pcall(function()
			stream:Close()
		end)
	end)

	stream.Closed:Connect(function()
		-- Stream ended. If onComplete hasn't fired, this was unexpected.
	end)

	return handle
end

-- Self-test
-- withMessageCache both shapes the request and has to leave the caller's
-- history alone, and each half fails silently in its own way: a tag written
-- into the live conversation accumulates until Anthropic rejects the request
-- over the 4-breakpoint cap, and a rewritten user message survives into the
-- saved session, where replay no longer recognises it.
local function selfTest(): (boolean, string?)
	local function countTags(messages: { any }): number
		local tags = 0
		for _, message in ipairs(messages) do
			if type(message.content) == "table" then
				for _, block in ipairs(message.content) do
					if type(block) == "table" and block.cache_control then tags += 1 end
				end
			end
		end
		return tags
	end

	local conversation: { any } = {
		{ role = "user", content = "hello" },
		{ role = "assistant", content = { { type = "text", text = "hi" } } },
		{ role = "user", content = "again" },
	}

	local wire = withMessageCache(conversation)
	if conversation[3].content ~= "again" then
		return false, "withMessageCache rewrote a live user message; session replay loses it"
	end
	if countTags(conversation) ~= 0 then
		return false, "withMessageCache tagged the live conversation"
	end
	if countTags(wire) ~= 1 then
		return false, string.format("withMessageCache put %d breakpoints in the request, expected 1", countTags(wire))
	end
	if type(wire[3].content) ~= "table" or wire[3].content[1].text ~= "again" then
		return false, "withMessageCache lost the text of the message it tagged"
	end

	-- Turn two: the same conversation, one message longer. Breakpoints must not
	-- accumulate across requests, that is the 4-cap failure.
	table.insert(conversation, { role = "assistant", content = { { type = "text", text = "ok" } } })
	table.insert(conversation, { role = "user", content = {
		{ type = "tool_result", tool_use_id = "t1", content = "ok" },
	} })
	local wire2 = withMessageCache(conversation)
	if countTags(wire2) ~= 1 then
		return false, string.format("withMessageCache accumulated %d breakpoints by turn two", countTags(wire2))
	end
	if conversation[#conversation].content[1].cache_control ~= nil then
		return false, "withMessageCache tagged a live tool_result block"
	end

	return true
end

return {
	Initialize = Initialize,
	streamMessage = streamMessage,
	selfTest = selfTest,
	MODELS = MODELS,
	webSearchTool = webSearchTool,
	DEFAULT_MODEL = DEFAULT_MODEL,
	_MESSAGES_URL = MESSAGES_URL,
	_ANTHROPIC_VERSION = ANTHROPIC_VERSION,
	_ANTHROPIC_BETA = ANTHROPIC_BETA,
	_CLAUDE_CODE_IDENTITY = CLAUDE_CODE_IDENTITY,
}
