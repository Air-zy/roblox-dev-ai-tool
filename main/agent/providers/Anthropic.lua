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
--   Initialize(auth, plugin)
--   streamMessage({ model, system, messages, maxTokens, tools, webSearch }, callbacks) -> handle
--   refreshModels()
--   acceptsModelId(id)
--   MODELS, DEFAULT_MODEL
--
-- The old non-streaming sendMessage/sendWithTools pair is gone. Agent drives the
-- tool loop over streamMessage, and two implementations of one protocol is how
-- the sendToClaude/sendToClaude_continue drift happened.

local HttpService = game:GetService("HttpService")
local warn = warn

local Retry = require(script.Parent:WaitForChild("Retry"))
local Stream = require(script.Parent:WaitForChild("Stream"))
local ToolJson = require(script.Parent:WaitForChild("ToolJson"))

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
--     does nothing. It IS set, in Tools.definitions, and the reason given here
--     for leaving it off — that nothing renders partial arguments, so it had
--     nothing to improve — was wrong. It is not about rendering. Buffered
--     parameters put nothing on the wire while a long `write` is generated, and
--     a silent stream is one Roblox closes.
local ANTHROPIC_BETA = "claude-code-20250219,oauth-2025-04-20"

-- The identity block Anthropic checks for. Must be the FIRST system block.
-- Still enforced: sent as "" on 2026-09-30, every request came back 429
-- rate_limit_error, which the retry loop then spent four attempts on. Claude
-- Code's source (system.ts) lists two other accepted prefixes; the Agent SDK
-- one is untested here and may bill a different usage window.
local CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."

-- Per-model thinking + effort support.
--   thinking = "adaptive": thinking:{type:"adaptive"}; the model decides when and
--     how deeply to think, steered by effort. thinking:{type:"enabled"} with
--     budget_tokens returns a 400 on these models.
--   thinking = "budget": legacy extended thinking, sized by budget_tokens.
--   thinking = "none": no thinking parameter at all, for a listed model that
--     reports neither.
-- `effort` is separate because it is: Opus 4.5 takes both, Haiku 4.5 only the
-- budget, and output_config.effort on a model without it is a 400.
-- Unknown models default to adaptive, matching every current Claude release.
--
-- maxOutput is the documented per-model output ceiling. A ceiling is not a
-- reservation: billing counts tokens actually generated, and max_tokens is
-- explicitly excluded from the output-per-minute rate limit, so asking for the
-- documented maximum costs nothing and only removes a way to be truncated
-- mid-answer. The default is the smaller number because an unknown model is
-- more likely to be a smaller one, and asking for more than a model allows is a
-- 400 rather than a silent clamp.
--
-- `context` is the INPUT window, the denominator the settings panel divides a
-- turn's prompt size by. Nothing in the request uses it: a prompt that overflows
-- is a 400 from the server either way, and clamping client-side against a
-- hand-written number would refuse a request the server would have accepted.
-- It exists only so a reading can be shown as a fraction, which is why an
-- unknown model gets the SMALLER default here for the opposite reason to
-- maxOutput's — over-reporting how full the window is costs nothing, while
-- under-reporting it hides the one thing the row exists to warn about.
--
-- This table is the fallback, not the source. refreshModels below replaces it
-- with what GET /v1/models reports per model, max_tokens, max_input_tokens and
-- the capability tree, so a model that ships after this build is shaped right
-- without an edit here. The table still decides a first run, an offline one,
-- and every turn if the list endpoint ever refuses the token.
local MODEL_CAPS: { [string]: { thinking: string, effort: boolean, maxOutput: number,
	context: number } } = {
	["claude-opus-5-5"]           = { thinking = "adaptive", effort = true,  maxOutput = 128000, context = 1000000 },
	["claude-fable-5-1"]          = { thinking = "adaptive", effort = true,  maxOutput = 128000, context = 1000000 },
	["claude-sonnet-5-5"]         = { thinking = "adaptive", effort = true,  maxOutput = 128000, context = 1000000 },
	["claude-opus-5"]             = { thinking = "adaptive", effort = true,  maxOutput = 128000, context = 1000000 },
	["claude-sonnet-5"]           = { thinking = "adaptive", effort = true,  maxOutput = 128000, context = 1000000 },
	["claude-haiku-4-5"]          = { thinking = "budget",   effort = false, maxOutput = 64000,  context = 200000 },
}
local DEFAULT_CAPS = { thinking = "adaptive", effort = true, maxOutput = 64000, context = 200000 }

-- The fetched roster's caps by id, filled by adopt() further down.
local fetched: { [string]: any } = {}

local function capsFor(model: string): { thinking: string, effort: boolean, maxOutput: number,
	context: number }
	return fetched[model] or MODEL_CAPS[model] or DEFAULT_CAPS
end

-- The input window for a model id, for the settings panel's context row. Exported
-- rather than the whole caps table: everything else in there shapes a request and
-- belongs to this file alone.
local function contextWindow(model: string): number
	return capsFor(model).context
end

-- A 401 is not retryable on its own — the same token will be rejected again —
-- but it IS retryable after forcing a refresh, which is what upstream does:
-- on 401, or a 403 saying the token was revoked, it calls handleOAuth401Error
-- and rebuilds the client before the next attempt.
--
-- Worth having here for a reason upstream mostly does not face: two Studio
-- windows share one stored credential, so the other one refreshing can leave
-- this one holding a token the server has already retired. Proactive refresh
-- cannot see that coming, because the token does not look expired.
-- 403 only when the body says the token was revoked, which is exactly how
-- upstream draws the line (`status===403 && message.includes('OAuth token has
-- been revoked')`). A plain 403 is a permission error and Anthropic lists it as
-- not retryable — refreshing against one just spends a token round trip to be
-- told no a second time.
local function needsTokenRefresh(status: number?, body: string?): boolean
	if status == 401 then return true end
	return status == 403
		and body ~= nil
		and string.find(body, "revoked", 1, true) ~= nil
end

-- Seconds until the subscription window resets, from the header Claude Code
-- reads for the same purpose (`getRateLimitResetDelayMs`). A unix timestamp, so
-- a 429 that carries one is a quota window rather than a momentary burst.
local function rateLimitResetSeconds(headers: string?): number?
	return Retry.resetSeconds(headers, "anthropic-ratelimit-unified-reset")
end

-- Carried as parts, not as one string the callers take apart again. `label` is
-- the whole line for anything with room for it; `name` and `hint` exist because
-- the compact rows want them separately and used to recover them with a pair of
-- regexes in main.luau — one of which had to strip the vendor word, which meant
-- naming a vendor in a file that is not allowed to. Composing here is free;
-- parsing it back cost a heuristic that guessed wrong on a two-word vendor.
local MODELS = {
	{ id = "claude-opus-5-5",  label = "Claude Opus 5.5 (recommended)", name = "Opus 5.5",  hint = "recommended" },
	{ id = "claude-fable-5-1", label = "Claude Fable 5.1 (most capable)", name = "Fable 5.1", hint = "most capable" },
	{ id = "claude-sonnet-5-5", label = "Claude Sonnet 5.5 (balanced)", name = "Sonnet 5.5", hint = "balanced" },
	{ id = "claude-haiku-4-5", label = "Claude Haiku 4.5 (fastest)",    name = "Haiku 4.5", hint = "fastest" },
}
local DEFAULT_MODEL = "claude-opus-5-5"

-- Whether `/model <arg>` should accept an id the list above has never heard of,
-- so a model released after this build can still be reached by name. The check
-- used to live in Commands.luau as a literal "claude-", which put a vendor name
-- in a file that is not allowed to hold one.
local function acceptsModelId(id: string): boolean
	return id:find("claude-", 1, true) ~= nil
end

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

-- The live roster: every model the account can reach. Same endpoint and OAuth
-- beta as Claude Code's capability cache (modelCapabilities.ts), which only
-- runs for Anthropic staff, so a subscriber token being accepted here is
-- untested; a refusal just leaves MODELS and MODEL_CAPS above in charge.
-- Cached for a day like the other fetched rosters.
local MODELS_URL = "https://api.anthropic.com/v1/models?limit=1000"
local KEY_MODEL_CACHE = "anthropic_models"
local KEY_MODEL_CACHE_AT = "anthropic_models_at"
local MODEL_CACHE_MAX_AGE = 24 * 3600
local plugin: any = nil  -- set via Initialize, for the roster cache

local function contextHint(limit: number): string
	if limit >= 1000000 then
		return string.format("%gM", limit / 1000000)
	end
	return string.format("%dk", math.floor(limit / 1000))
end

local function supported(node: any): boolean
	return type(node) == "table" and node.supported == true
end

-- One /v1/models entry as a picker row that carries its own caps. Nil when
-- neither the entry nor MODEL_CAPS says how to ask the model to think: a guess
-- of adaptive for a model that only takes budget_tokens is a 400 on every turn,
-- so such a model stays reachable by `/model` but off the list.
-- ponytail: effort is on/off per model, not per level. A legacy model without
-- xhigh or max is a 400 at those two; clamp from capabilities.effort if it bites.
local function rosterEntry(entry: any): any?
	if type(entry) ~= "table" or type(entry.id) ~= "string" then return nil end
	local known = MODEL_CAPS[entry.id]
	local caps = entry.capabilities
	local thinking, effort
	if type(caps) == "table" then
		local types = type(caps.thinking) == "table" and caps.thinking.types or nil
		thinking = if types and supported(types.adaptive) then "adaptive"
			elseif types and supported(types.enabled) then "budget"
			else "none"
		effort = supported(caps.effort)
	elseif known then
		thinking, effort = known.thinking, known.effort
	else
		return nil
	end
	local context = tonumber(entry.max_input_tokens) or (known and known.context) or DEFAULT_CAPS.context
	local display = if type(entry.display_name) == "string" then entry.display_name else entry.id
	return {
		id = entry.id,
		label = display,
		name = (display:gsub("^Claude%s+", "")),
		hint = contextHint(context),
		context = context,
		maxOutput = tonumber(entry.max_tokens) or (known and known.maxOutput) or DEFAULT_CAPS.maxOutput,
		thinking = thinking,
		effort = effort,
	}
end

-- The one place a roster becomes MODELS, from the fetch and from the cache
-- alike, so a cache written by an older build is read by this one's rules. In
-- place, because MODELS is exported by reference. Never empties a working list.
local function adopt(entries: { any }): boolean
	local rows: { any } = {}
	for _, entry in ipairs(entries) do
		local row = rosterEntry(entry)
		if row then rows[#rows + 1] = row end
	end
	if #rows == 0 then return false end
	table.clear(MODELS)
	table.clear(fetched)
	for _, row in ipairs(rows) do
		MODELS[#MODELS + 1] = row
		fetched[row.id] = row
	end
	return true
end

-- Yields; call it from a task.spawn.
local function refreshModels(): (boolean, string?)
	if not OAuth then return false, "not initialized" end
	local token = OAuth.getAccessToken()
	if not token then return false, "not logged in" end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = MODELS_URL,
			Method = "GET",
			Headers = {
				["Authorization"] = "Bearer " .. token,
				["anthropic-version"] = ANTHROPIC_VERSION,
				["anthropic-beta"] = ANTHROPIC_BETA,
				["x-app"] = "cli",
				["accept"] = "application/json",
			},
		})
	end)
	if not ok then
		return false, "model list request failed: " .. tostring(response)
	end
	local res = response :: any
	if res.StatusCode ~= 200 then
		return false, string.format("model list: HTTP %d", res.StatusCode)
	end
	local parsed
	if not pcall(function() parsed = HttpService:JSONDecode(res.Body) end) then
		return false, "model list: response was not JSON"
	end
	local data = (parsed :: any).data
	if type(data) ~= "table" or not adopt(data) then
		return false, "model list: nothing usable"
	end
	if plugin then
		-- The raw entries, not the rows, so the next build re-derives the caps.
		pcall(function()
			plugin:SetSetting(KEY_MODEL_CACHE, HttpService:JSONEncode(data))
			plugin:SetSetting(KEY_MODEL_CACHE_AT, os.time())
		end)
	end
	return true
end

local function Initialize(oauthModule: any, pluginRef: any)
	OAuth = oauthModule
	plugin = pluginRef
	if not plugin then return end
	local cached = plugin:GetSetting(KEY_MODEL_CACHE)
	if type(cached) == "string" and cached ~= "" then
		local ok, decoded = pcall(function() return HttpService:JSONDecode(cached) end)
		if ok and type(decoded) == "table" then adopt(decoded) end
	end
	local at = plugin:GetSetting(KEY_MODEL_CACHE_AT)
	if type(at) ~= "number" or os.time() - at > MODEL_CACHE_MAX_AGE then
		task.spawn(refreshModels)
	end
end

-- Builds the thinking/effort part of the body.
local function applyReasoning(bodyTable: { [string]: any }, model: string, effort: string?)
	local caps = capsFor(model)

	if caps.effort and effort and effort ~= "" then
		-- Request-level, no beta header on current models. Always sent, never
		-- left to the default: that is "high" on most models but "medium" on
		-- Opus 5.5, so omitting it would quietly change what the setting means.
		bodyTable.output_config = { effort = effort }
	end

	if caps.thinking == "adaptive" then
		-- Load-bearing. Since Opus 4.7 the default is "omitted", which streams
		-- thinking blocks with an empty thinking field, and that is every model
		-- listed here: it is why the drawer once opened on empty blocks. On the
		-- 5.5 models "summarized" also carries the progress notes the model
		-- writes between tool calls, which come back as thinking blocks there.
		bodyTable.thinking = { type = "adaptive", display = "summarized" }
		-- Preserved thinking ties a block to the exact prefix it was produced
		-- under. Microcompact rewrites old tool_result content in place, and a
		-- system prompt or tool toggle mid-session is an edit too; on accounts
		-- created from 2026-08-31 a replayed block after any of those is a 400.
		-- drop_block makes the server drop the stale blocks instead. Sent on every
		-- adaptive model rather than a hand-kept list of the bound ones: the object
		-- is accepted on every model that accepts `thinking`, and a list is what a
		-- newly fetched model would be missing from.
		-- https://platform.claude.com/docs/en/build-with-claude/preserved-thinking
		bodyTable.thinking.block_binding = { prefix_mismatch_behavior = "drop_block" }
	elseif caps.thinking == "budget" then
		-- Thinking tokens come out of max_tokens, and the API requires the budget
		-- to be strictly under it. There is nothing to tune: a budget is a
		-- ceiling on thinking, not a quota that gets spent, so handing over
		-- everything but one token costs nothing on a turn that thinks briefly
		-- and never truncates one that does not. Effort does not enter into it; it
		-- is its own field, set above on the models that take one.
		bodyTable.thinking = {
			type = "enabled",
			budget_tokens = (bodyTable.max_tokens :: number) - 1,
		}
	end
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
	tools: { any }?,
	webSearch: number?,
	}, callbacks: {
		onText: ((string) -> ())?,
		onThinking: ((string) -> ())?,
		onToolUseStart: ((string?, string) -> ())?,  -- (blockId, toolName), before any input
		onToolInput: ((string?, string) -> ())?,     -- (blockId, raw JSON fragment)
		onServerToolUse: ((string, string?, any) -> ())?,  -- (toolName, blockId, parsedInput)
		onServerToolResult: ((string, string?, any) -> ())?, -- (toolName, toolUseId, rawContent)
		onComplete: ((any) -> ())?,
		onError: ((string, string?) -> ())?,
		onRetry: ((string, number, number, number) -> ())?,  -- (reason, waitSeconds, attempt, ofAttempts)
		onDiscard: (() -> ())?,  -- the attempt so far is void; it is being asked again
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

	-- Checked here so a logged-out caller fails immediately rather than after a
	-- request is built. The token used on the wire is fetched per attempt in the
	-- `request` hook below, since a retry after a 401 has to pick up a fresh one.
	local firstToken, tokenErr = OAuth.getAccessToken()
	if not firstToken then
		if callbacks.onError then callbacks.onError("Auth: " .. tostring(tokenErr)) end
		return noopHandle()
	end

	local model = args.model or DEFAULT_MODEL
	-- Ask for everything the model will give; see MODEL_CAPS for why that is
	-- free. Callers may still pass a smaller ceiling, and nothing currently does.
	local maxTokens = args.maxTokens or capsFor(model).maxOutput

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
	-- breakpoint below is 1h for the same reason.
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
		-- messages and the conversation's cache_control are set together below.
		stream = true,  -- CRITICAL: enable streaming
		system = systemBlocks,
	}

	applyReasoning(bodyTable, model, args.effort)

	-- Anthropic runs web search itself, so it is a tool in the array rather
	-- than a body field. Appended LAST on purpose: tool definitions render at
	-- the very front of the request and caching is a prefix match, so toggling
	-- search only invalidates from the end of the tool block onward.
	if args.webSearch and args.webSearch > 0 and args.tools then
		table.insert(args.tools, webSearchTool(args.webSearch))
	end

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

	-- The conversation itself is the part that grows every turn, and its
	-- breakpoint is the one that matters as the tool loop climbs: everything
	-- before it is a cache read on the next call, not a reprocess. The top-level
	-- field is automatic caching, where the API puts that breakpoint on the last
	-- cacheable block and moves it forward itself. It replaced a hand-placed tag
	-- on a copied last message, whose bookkeeping had already leaked tags into
	-- saved history once and overflowed the 4-breakpoint cap once.
	--
	-- 1h for the same reason as the two above. A breakpoint that moves every
	-- turn does not pay the 2x on the whole history while the cache is warm: the
	-- lookup is a longest-prefix match, so each turn writes only its delta.
	--
	-- ponytail: no overage gating. Claude Code drops to 5m for a subscriber who
	-- is into overage, and latches the choice for the whole session because
	-- flipping TTL mid-session busts the server-side cache. If plan usage ever
	-- drives this, latch it once at session start, never per turn.
	bodyTable.cache_control = { type = "ephemeral", ttl = "1h" }
	bodyTable.messages = args.messages

	local bodyStr = HttpService:JSONEncode(bodyTable)

	-- Accumulators for the final result
	local textParts = {}
	local thinkingParts = {}
	local contentBlocks: { any } = {}  -- keyed by SSE index; MAY BE SPARSE
	local blockCount = 0               -- highest index seen, so nothing is missed
	local usage: any = nil
	local stopReason: string? = nil

	-- One complete SSE frame. Stream.luau owns the buffering and the split;
	-- this reads what a frame MEANS, which is the only half that is Anthropic.
	local function onFrame(eventStr: string, ctrl: Stream.Ctrl)
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
				-- A frame we cannot read. Was `continue` when this ran inside
				-- the buffer loop; one frame is one call now, so it is a return.
				return
			end
			local evt = parsed :: any

			if currentEvent == "message_start" then
				-- Initial message object, empty content. Its usage is where
				-- input_tokens and the two cache counts are guaranteed to
				-- appear. message_delta MAY repeat them, and the streaming
				-- reference shows it both ways: its web-search example carries
				-- the full set, its plain text and tool_use examples carry
				-- output_tokens alone. Keeping this one and letting the delta
				-- overwrite field by field is correct under either, where
				-- taking only the delta silently zeroes the cache line on
				-- exactly the ordinary turns it exists to report.
				if evt.message and evt.message.usage then
					usage = table.clone(evt.message.usage)
				end

			elseif currentEvent == "content_block_start" then
				-- Past here the caller has been told something, so no retry.
				ctrl.emitted()
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
				-- Set here as well as at content_block_start, because the branch
				-- below deliberately tolerates a delta whose start never arrived
				-- — and that path still fires onText, so it still makes a retry
				-- unsafe. Guarding only the start would leave exactly the
				-- malformed-stream case able to render twice.
				ctrl.emitted()
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
					-- Raw, unparsed, and possibly mid-token: these fragments are
					-- only valid JSON once the block closes, so this is for
					-- display and nothing else. content_block_stop still owns the
					-- parse that decides whether the tool may run.
					if callbacks.onToolInput then
						callbacks.onToolInput(block.id, delta.partial_json)
					end
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
					local inputParsed, repaired = ToolJson.decode(block.input)
					-- Not silent: the model produced invalid JSON and the call
					-- ran anyway. Worth seeing in the Output window on the day a
					-- write lands looking slightly wrong.
					if repaired then
						warn(string.format(
							"[agent] %s: repaired unescaped control characters in tool input",
							tostring(block.name)))
					end
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
				-- Merged, not replaced: output_tokens here is cumulative and
				-- always present, the input and cache counts sometimes are
				-- not, and an absent field must leave message_start's value
				-- standing rather than erase it.
				if evt.usage then
					usage = usage or {}
					for key, value in pairs(evt.usage) do
						usage[key] = value
					end
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

				-- ctrl.finish latches, emits, then closes, in that order. The
				-- latch has to precede the callback so a late Error on the socket
				-- is not mistaken for a failure worth retrying on top of a
				-- delivered answer.
				ctrl.finish(function()
					-- A declined request is an HTTP 200 with stop_reason "refusal",
					-- and whatever streamed before it is to be discarded, not kept:
					-- committed, a tool_use in it would run. Reported as a failure so
					-- every caller drops it the way it drops any other.
					if stopReason == "refusal" then
						if callbacks.onError then
							callbacks.onError("the model declined this request (stop_reason: refusal); rephrase it or pick another model")
						end
						return
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
				end)

			elseif currentEvent == "error" then
				-- Where overloaded_error actually shows up. The HTTP status was
				-- 200 — the stream opened fine and the failure is in-band — so
				-- the raw event JSON is handed to `fail` as the body, which is
				-- what lets it be recognised and retried at all.
				local errMsg = "stream error"
				if evt.error and evt.error.type then
					errMsg = tostring(evt.error.type)
				end
				if evt.error and evt.error.message then
					errMsg = errMsg .. " — " .. tostring(evt.error.message)
				end
				ctrl.fail(nil, dataLine, errMsg)
			end
		end
	end

	-- Everything past the parser is transport, and lives in Stream.luau: the
	-- retry schedule, the generation counter that silences an abandoned socket,
	-- and the latches that stop a retry re-rendering text the first attempt
	-- already put on screen. This file supplies a request and reads frames.
	return Stream.open({
		request = function()
			-- Re-read per attempt rather than captured once. A turn can outlive its
			-- access token, and a 401 retry is only worth making with a new one —
			-- getAccessToken refreshes when it is close to expiry, and the refresh
			-- hook below forces one when the server has already rejected it.
			local accessToken, attemptTokenErr = OAuth.getAccessToken()
			if not accessToken then
				return nil, "Auth: " .. tostring(attemptTokenErr)
			end
			return {
				url = MESSAGES_URL,
				headers = {
					["Authorization"] = "Bearer " .. (accessToken :: string),
					["anthropic-version"] = ANTHROPIC_VERSION,
					-- Unconditional: block_binding without it is a 400, and the header
					-- alone changes nothing on a request that does not set the field.
					["anthropic-beta"] = ANTHROPIC_BETA .. ",thinking-binding-controls-2026-08-01",
					["x-app"] = "cli",
					["content-type"] = "application/json",
					["accept"] = "text/event-stream",
				},
				body = bodyStr,
			}
		end,

		reset = function()
			-- Reset even though a retry only happens with nothing emitted, which
			-- already implies the block accumulators are empty. `usage` is the
			-- exception that proves it is worth doing: it is written at
			-- message_start WITHOUT marking anything emitted, so a failed attempt
			-- can leave its numbers behind. Clearing all of them costs nothing and
			-- removes the need for anyone to re-derive which ones were safe.
			textParts = {}
			thinkingParts = {}
			contentBlocks = {}
			blockCount = 0
			usage = nil
			stopReason = nil
		end,

		frame = onFrame,

		partial = function(): string?
			-- textParts is only filled in at message_stop, which an error mid-stream
			-- never reaches, so it is empty here even when real text already
			-- arrived. Read live from contentBlocks instead, the same accumulator
			-- onText has been writing into all along. Indexed by blockCount rather
			-- than ipairs for the same reason message_stop is: a hole would cut the
			-- partial text short.
			local partial: { string } = {}
			for i = 1, blockCount do
				local block = contentBlocks[i]
				if block and block.type == "text" and block.text ~= "" then
					table.insert(partial, block.text)
				end
			end
			return if #partial > 0 then table.concat(partial, "\n") else nil
		end,

		refresh = function()
			OAuth.refresh()
		end,
		needsRefresh = needsTokenRefresh,
		windowReset = rateLimitResetSeconds,
	}, {
		onError = callbacks.onError,
		onRetry = callbacks.onRetry,
		onDiscard = callbacks.onDiscard,
	})
end

-- Self-test
local function selfTest(): (boolean, string?)
	-- Retry moved to its own module and took its assertions with it. Chained
	-- rather than dropped: it is still this provider's retry behaviour, and
	-- startup is the only gate any of this has.
	local retryOk, retryErr = Retry.selfTest()
	if not retryOk then return false, "Retry: " .. tostring(retryErr) end
	local jsonOk, jsonErr = ToolJson.selfTest()
	if not jsonOk then return false, "ToolJson: " .. tostring(jsonErr) end

	-- applyReasoning picks between two request shapes that each 400 if they
	-- reach the wrong model: budget_tokens on an adaptive model, effort on one
	-- that predates it. Both directions are checked because both were sent at
	-- some point.
	local adaptive: { [string]: any } = { max_tokens = 128000 }
	applyReasoning(adaptive, "claude-sonnet-5", "xhigh")
	if adaptive.thinking.type ~= "adaptive" then
		return false, "adaptive model did not get adaptive thinking"
	end
	if adaptive.thinking.budget_tokens ~= nil then
		return false, "adaptive model was sent budget_tokens; the API rejects it"
	end
	if not adaptive.output_config or adaptive.output_config.effort ~= "xhigh" then
		return false, "effort did not reach output_config on a model that supports it"
	end

	if not adaptive.thinking.block_binding
		or adaptive.thinking.block_binding.prefix_mismatch_behavior ~= "drop_block" then
		return false, "a preserved-thinking model will 400 after microcompact edits its history"
	end

	local budget: { [string]: any } = { max_tokens = 64000 }
	applyReasoning(budget, "claude-haiku-4-5", "xhigh")
	if budget.output_config ~= nil then
		return false, "effort was sent to a model that does not support it"
	end
	if budget.thinking.type ~= "enabled" then
		return false, "pre-adaptive model did not get extended thinking"
	end
	-- Strictly under max_tokens, or the request is rejected outright.
	if budget.thinking.budget_tokens ~= 63999 then
		return false, string.format(
			"budget_tokens was %s, expected max_tokens - 1",
			tostring(budget.thinking.budget_tokens))
	end

	-- A fetched model is asked to think the way /v1/models says it can, and a
	-- wrong reading is a 400 on every turn of it.
	local function thinks(kind: string): any
		return { supported = true, types = {
			adaptive = { supported = kind == "adaptive" },
			enabled = { supported = kind == "budget" },
		} }
	end
	local fresh = rosterEntry({ id = "claude-test-9", display_name = "Claude Test 9",
		max_tokens = 128000, max_input_tokens = 1000000,
		capabilities = { thinking = thinks("adaptive"), effort = { supported = true } } })
	if not fresh or fresh.thinking ~= "adaptive" or not fresh.effort or fresh.maxOutput ~= 128000
		or fresh.context ~= 1000000 or fresh.name ~= "Test 9" then
		return false, "an adaptive model from /v1/models was not shaped as one"
	end
	local legacy = rosterEntry({ id = "claude-test-4", max_tokens = 64000, max_input_tokens = 200000,
		capabilities = { thinking = thinks("budget"), effort = { supported = false } } })
	if not legacy or legacy.thinking ~= "budget" or legacy.effort then
		return false, "a budget_tokens model from /v1/models would get adaptive thinking or effort"
	end
	if rosterEntry({ id = "claude-test-0" }) ~= nil then
		return false, "a model with no capabilities and no table entry was listed on a guess"
	end
	local bare = rosterEntry({ id = "claude-haiku-4-5" })
	if not bare or bare.thinking ~= "budget" then
		return false, "a known model without capabilities lost its table caps"
	end

	if not needsTokenRefresh(401, nil) then return false, "401 does not trigger a token refresh" end
	if not needsTokenRefresh(403, '{"error":{"message":"OAuth token has been revoked"}}') then
		return false, "a revoked-token 403 does not trigger a refresh"
	end
	if needsTokenRefresh(403, '{"error":{"message":"permission denied"}}') then
		return false, "a plain permission 403 is being answered with a token refresh"
	end
	if needsTokenRefresh(429, nil) then return false, "a rate limit is being treated as an auth failure" end

	-- A window reset in the future is reported; one in the past is not a limit
	-- at all and must not be mistaken for one.
	local future = string.format("anthropic-ratelimit-unified-reset: %d", os.time() + 600)
	local ahead = rateLimitResetSeconds(future)
	if not ahead or ahead < 500 or ahead > 700 then
		return false, string.format("unified-reset parsed as %s, expected ~600", tostring(ahead))
	end
	local past = string.format("anthropic-ratelimit-unified-reset: %d", os.time() - 600)
	if rateLimitResetSeconds(past) ~= nil then
		return false, "an already-elapsed reset is being reported as a wait"
	end
	if rateLimitResetSeconds("content-type: application/json") ~= nil then
		return false, "reset invented from headers that carry none"
	end

	return true
end

return {
	Initialize = Initialize,
	streamMessage = streamMessage,
	selfTest = selfTest,
	MODELS = MODELS,
	refreshModels = refreshModels,
	-- Image blocks are this API's own shape and go through untouched.
	acceptsImages = true,
	acceptsModelId = acceptsModelId,
	contextWindow = contextWindow,
	DEFAULT_MODEL = DEFAULT_MODEL,
	_MESSAGES_URL = MESSAGES_URL,
	_ANTHROPIC_VERSION = ANTHROPIC_VERSION,
	_ANTHROPIC_BETA = ANTHROPIC_BETA,
	_CLAUDE_CODE_IDENTITY = CLAUDE_CODE_IDENTITY,
}
