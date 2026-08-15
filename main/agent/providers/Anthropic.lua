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
--     does nothing. It IS set, in Tools.definitions, and the reason given here
--     for leaving it off — that nothing renders partial arguments, so it had
--     nothing to improve — was wrong. It is not about rendering. Buffered
--     parameters put nothing on the wire while a long `write` is generated, and
--     a silent stream is one Roblox closes.
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
--
-- maxOutput is the documented per-model output ceiling. A ceiling is not a
-- reservation: billing counts tokens actually generated, and max_tokens is
-- explicitly excluded from the output-per-minute rate limit, so asking for the
-- documented maximum costs nothing and only removes a way to be truncated
-- mid-answer. The default is the smaller number because an unknown model is
-- more likely to be a smaller one, and asking for more than a model allows is a
-- 400 rather than a silent clamp.
--
-- ponytail: hand-written, and it goes stale the day a model ships — the numbers
-- here were copied from Claude Code's own table and were already wrong for two
-- of these three. Claude Code keeps the same table but treats it as a fallback
-- under GET /v1/models, which reports max_tokens per model and is the upgrade
-- path if this is ever wrong again. Three models and a 400 that says so is not
-- yet worth a fetch and a cache.
local MODEL_CAPS: { [string]: { thinking: string, effort: boolean, maxOutput: number } } = {
	["claude-opus-5"]             = { thinking = "adaptive", effort = true,  maxOutput = 128000 },
	["claude-sonnet-5"]           = { thinking = "adaptive", effort = true,  maxOutput = 128000 },
	["claude-haiku-4-5"]          = { thinking = "budget",   effort = false, maxOutput = 64000 },
}
local DEFAULT_CAPS = { thinking = "adaptive", effort = true, maxOutput = 64000 }

local function capsFor(model: string): { thinking: string, effort: boolean, maxOutput: number }
	return MODEL_CAPS[model] or DEFAULT_CAPS
end

-- Retry, following Claude Code's withRetry.ts rather than inventing a schedule.
-- Theirs: BASE_DELAY_MS = 500, `min(500 * 2^(attempt-1), 32000)` plus up to 25%
-- jitter, and a `retry-after` taken literally — it deliberately bypasses the cap
-- there, being a server directive. DEFAULT_MAX_RETRIES = 10, with 529 held to a
-- separate MAX_529_RETRIES = 3, since an overloaded fleet is not helped by ten
-- of us.
--
-- The counts are lower here on purpose. Upstream is a CLI someone is watching in
-- a terminal; this is a docked widget where ten backoffs is over a minute of a
-- spinner saying nothing, with Stop as the only way out.
-- Attempts, not retries: the first try counts, so 4 here is one request and
-- three more. Named for what the code compares against, because "MAX_RETRIES = 4"
-- next to `attempts < MAX_RETRIES` reads as one more try than it performs.
-- From the source, and verified against the shipped bundle rather than only the
-- leak: `min(500 * 2^(attempt-1), 32000)` with up to 25% jitter.
local BASE_DELAY = 0.5
local MAX_DELAY = 32

-- NOT from the source. Upstream retries 10 times; four is a judgement call for a
-- docked widget, where the whole schedule has to stay inside the patience of
-- someone watching a spinner. Four attempts is at most ~8s of backoff.
local MAX_ATTEMPTS = 4
-- Their MAX_529_RETRIES is also 3, but theirs counts RETRIES and this counts
-- ATTEMPTS, so this is the tighter of the two despite the matching number.
-- Deliberate: an overloaded fleet is the one case where coming back less is
-- strictly better for everyone.
local MAX_OVERLOAD_ATTEMPTS = 3
-- NOT from the source, and there is no upstream equivalent — they sleep through
-- a quota window in unattended mode instead. Past a minute, waiting is no longer
-- something to do behind a spinner without saying so, and the reset time is more
-- useful to a person than four doomed attempts.
local WINDOW_LIMIT_SECONDS = 60

local function retryDelay(attempt: number, retryAfter: number?): number
	local base = math.min(BASE_DELAY * 2 ^ (attempt - 1), MAX_DELAY)
	-- Jitter so several Studio windows that failed together do not come back in
	-- lockstep and rebuild the pileup they were caught in.
	local delay = base + math.random() * 0.25 * base
	-- The LARGER of the two, which is what ships: `Math.max(A*1000, Y)`. The
	-- leaked tree returns retry-after bare, and that is the older behaviour —
	-- worth knowing, because a server answering `retry-after: 1` would then pin
	-- every attempt at one second while the backoff never got to grow.
	if retryAfter then return math.max(retryAfter, delay) end
	return delay
end

-- What is worth trying again. Deliberately a short list: anything not named here
-- fails the turn, because a retry that cannot succeed just spends the user's
-- time twice.
--
-- 529 is matched on the BODY as well as the status. Upstream does the same, and
-- says why: "the SDK sometimes fails to properly pass the 529 status code during
-- streaming". That applies doubly here, where an overloaded_error arrives as an
-- SSE `event: error` inside a response whose HTTP status was already 200.
--
-- InactivityTimeout is ours. Roblox closes a stream that goes quiet, which
-- happens when the server is still reading an uncached prefix and has sent
-- nothing yet. Retrying is the right move precisely because the failed attempt
-- still warmed that prefix, so the second one starts talking sooner.
-- Anthropic publishes which statuses are worth retrying, and the table ships
-- inside Claude Code's own bundle: 400, 401, 403, 404 and 413 are No; 429
-- (rate_limit_error), 500 (api_error) and 529 (overloaded_error) are Yes. The
-- 5xx range is included rather than 500 alone because 502 and 503 come from
-- infrastructure in front of the API and mean the same thing to a client.
local function isRetryable(status: number?, body: string?): boolean
	if status == 429 then return true end
	if status and status >= 500 and status < 600 then return true end
	if not body then return false end
	-- Body matching as well as status for the same reason upstream does it: the
	-- status is not always the thing that arrives. rate_limit_error is included
	-- alongside overloaded_error because both can reach us through a path that
	-- carried no usable status at all.
	return string.find(body, '"type":"overloaded_error"', 1, true) ~= nil
		or string.find(body, '"type":"rate_limit_error"', 1, true) ~= nil
		or string.find(body, "InactivityTimeout", 1, true) ~= nil
end

local function isOverload(status: number?, body: string?): boolean
	return status == 529
		or (body ~= nil and string.find(body, '"type":"overloaded_error"', 1, true) ~= nil)
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
	if not headers then return nil end
	local value = string.match(headers:lower(), "anthropic%-ratelimit%-unified%-reset:%s*(%d+)")
	local reset = if value then tonumber(value) else nil
	if not reset then return nil end
	local delay = reset - os.time()
	return if delay > 0 then delay else nil
end

-- `retry-after` out of the raw header blob WebStreamClient hands to Opened. A
-- server directive beats our own schedule, so this is preferred over the
-- backoff when present — upstream lets it bypass the delay cap for the same
-- reason. Seconds only: the HTTP-date form is legal but Anthropic sends the
-- delta form, and guessing wrong on a date is worse than falling back.
local function retryAfterSeconds(headers: string?): number?
	if not headers then return nil end
	-- Lowercased first because Lua patterns have no case-insensitivity flag and
	-- header names are case-insensitive per HTTP. The alternative is spelling out
	-- a bracket class per letter, which is what this was and which nobody should
	-- have to read. A header blob is a few hundred bytes and this runs once per
	-- failed attempt, so the copy costs nothing worth measuring.
	local value = string.match(headers:lower(), "retry%-after:%s*(%d+)")
	return if value then tonumber(value) else nil
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
local function applyReasoning(bodyTable: { [string]: any }, model: string, effort: string?)
	local caps = capsFor(model)

	if caps.effort and effort and effort ~= "" then
		-- Request-level, no beta header on current models. "high" is the API
		-- default, so passing it is the same as omitting it.
		bodyTable.output_config = { effort = effort }
	end

	if caps.thinking == "adaptive" then
		-- "summarized" is the documented default, and Claude Code omits the field
		-- entirely, so this is explicit rather than load-bearing. It is spelled
		-- out because the drawer once opened on blocks whose thinking field was
		-- empty, which "omitted" would explain — but that was a guess, and the
		-- API reference contradicts it. The real cause was never found. If empty
		-- thinking blocks come back, this line is not what fixed it.
		bodyTable.thinking = { type = "adaptive", display = "summarized" }
	elseif caps.thinking == "budget" then
		-- Thinking tokens come out of max_tokens, and the API requires the budget
		-- to be strictly under it. There is nothing to tune: a budget is a
		-- ceiling on thinking, not a quota that gets spent, so handing over
		-- everything but one token costs nothing on a turn that thinks briefly
		-- and never truncates one that does not. Effort does not enter into it —
		-- these are the models that reject output_config.effort outright.
		bodyTable.thinking = {
			type = "enabled",
			budget_tokens = (bodyTable.max_tokens :: number) - 1,
		}
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
	tools: { any }?,
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
	-- request is built. The token used on the wire is fetched per attempt inside
	-- `start`, since a retry after a 401 has to pick up a refreshed one.
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

	applyReasoning(bodyTable, model, args.effort)

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

	-- Set the moment anything reaches the caller, and it is what makes retrying
	-- safe: onText has already been appended to a bubble and onToolUseStart has
	-- already put a block on screen, so a second attempt would render both twice
	-- and there is no callback for "forget what I just told you". A retry is
	-- therefore only ever offered before the first content block. That is not
	-- much of a restriction in practice, because the failures worth retrying —
	-- 429, 529, a stream that went quiet waiting on an uncached prefix — all
	-- happen before the model has said anything.
	local emitted = false
	-- Per-attempt latch. Distinct from handle.cancelled, which means the USER
	-- stopped this and must never be undone; this one only means the current
	-- socket is finished, and a retry clears it.
	local dead = false
	-- Bumped by every attempt, and captured by that attempt's handlers. Closing a
	-- WebStreamClient does not disconnect what is bound to it, so without this a
	-- late event from the socket we just abandoned arrives after `dead` has been
	-- cleared for the retry, and gets processed as though it belonged to the new
	-- attempt — an old Error would kill a request that is working.
	local generation = 0
	-- Attempts made including the one in flight, and the subset of them that were
	-- overloads. Two counters because they cap differently, the way upstream
	-- tracks `attempt` and `consecutive529Errors` separately.
	local attempts = 1
	local overloadAttempts = 0
	-- Latched, so a token refresh is tried once per request and never becomes a
	-- loop against an endpoint that keeps saying no.
	local refreshed = false

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
		if handle.cancelled or dead then return end
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
					emitted = true
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
					emitted = true
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

					-- Latched before the callback: this attempt succeeded, and a
					-- late Error on the socket must not now be mistaken for a
					-- failure worth retrying on top of a delivered answer.
					dead = true
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
					fail(nil, dataLine, errMsg)
				end
			end
		end
	end

	-- Timing lives outside `start` so a retry can report the whole wait rather
	-- than only its own attempt, and is reset per attempt below.
	local startedAt = os.time()
	local firstByteAt: number? = nil

	-- Forward-declared so `fail` can re-enter it.
	local start: (() -> ())
	-- The raw header blob from Opened, kept so a 429 can be answered on the
	-- server's own schedule rather than ours.
	local responseHeaders: string? = nil
	-- The HTTP status from Opened. Load-bearing, and easy to lose: with
	-- RawStream a 401 or 429 arrives as a normal response whose JSON body comes
	-- through MessageReceived, so the status is ONLY ever seen here. Passing nil
	-- from that path silently disabled auth refresh, window-limit reporting and
	-- rate-limit retries all at once, since each of them keys off the number.
	local responseStatus: number? = nil

	-- One decision point for every way an attempt can die: a transport Error, an
	-- SSE `error` event, and a JSON error body all route here rather than each
	-- calling onError with its own idea of what is fatal.
	local function fail(status: number?, body: string?, message: string)
		if handle.cancelled or dead then return end
		dead = true  -- latch first: a late MessageReceived must not race this
		pcall(function()
			if stream then stream:Close() end
		end)

		-- A quota window, not a burst. Backing off 32 seconds against a limit that
		-- resets in three hours only spends the attempts and arrives at the same
		-- refusal, so this reports the wait instead of pretending to ride it out.
		-- Upstream can afford to sleep through one because it has an unattended
		-- mode; a docked widget has a person in front of it.
		--
		-- Rewrites the message and falls through rather than answering here, so
		-- the partial-text handover at the bottom stays the single exit. An
		-- earlier version returned early and silently dropped whatever the model
		-- had already written.
		local resetIn = if status == 429 then rateLimitResetSeconds(responseHeaders) else nil
		local windowed = resetIn ~= nil and resetIn > WINDOW_LIMIT_SECONDS
		if windowed then
			message = string.format("%s — usage limit reached, resets in %d min",
				message, math.ceil((resetIn :: number) / 60))
		end

		-- One forced refresh, then the retry carries a new token. Bounded to once
		-- because a second 401 on a freshly minted credential is a real auth
		-- failure, and looping on it would just relogin-spam the token endpoint.
		if needsTokenRefresh(status, body) and not refreshed and not emitted
			and not windowed and attempts < MAX_ATTEMPTS then
			refreshed = true
			attempts += 1
			warn(string.format("[Claude Code] %s — refreshing token and retrying", message))
			task.spawn(function()
				if handle.cancelled then return end
				-- Yields on an HTTP round trip, which is why this is not inline:
				-- `fail` runs inside a stream event handler.
				OAuth.refresh()
				if handle.cancelled then return end
				start()
			end)
			return
		end

		local overload = isOverload(status, body)
		if overload then overloadAttempts += 1 end
		-- Both caps apply. The overall one bounds how long a user waits; the
		-- overload one is tighter because a fleet that is already saturated is
		-- not helped by us coming back four times.
		local allowed = attempts < MAX_ATTEMPTS
			and not windowed
			and (not overload or overloadAttempts < MAX_OVERLOAD_ATTEMPTS)
		if not emitted and allowed and isRetryable(status, body) then
			local wait = retryDelay(attempts, retryAfterSeconds(responseHeaders))
			attempts += 1
			warn(string.format("[Claude Code] %s — retrying in %.1fs (attempt %d/%d)",
				message, wait, attempts, MAX_ATTEMPTS))
			-- Said out loud, because a silent backoff is indistinguishable from
			-- the hang this whole mechanism exists to survive: same spinner, same
			-- nothing, for up to eight seconds. The caller decides how to show it;
			-- this file does not reach into the UI.
			if callbacks.onRetry then
				callbacks.onRetry(message, wait, attempts, MAX_ATTEMPTS)
			end
			task.delay(wait, function()
				-- Re-checked after the wait: Stop during a backoff must not be
				-- answered by opening another socket.
				if handle.cancelled then return end
				start()
			end)
			return
		end

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
			callbacks.onError(message, #partial > 0 and table.concat(partial, "\n") or nil)
		end
	end

	start = function()
		dead = false
		sseBuffer = ""
		responseHeaders = nil
		-- Reset even though a retry only happens with `emitted` false, which
		-- already implies the block accumulators are empty. `usage` is the
		-- exception that proves it is worth doing: it is written at message_start
		-- WITHOUT setting emitted, so a failed attempt can leave its numbers
		-- behind. Clearing all of them costs nothing and removes the need for
		-- anyone to re-derive which ones were safe.
		textParts = {}
		thinkingParts = {}
		contentBlocks = {}
		blockCount = 0
		usage = nil
		stopReason = nil
		generation += 1
		-- Captured, not read live: every handler below belongs to THIS socket and
		-- must go silent the moment a later attempt supersedes it.
		local myGeneration = generation

		-- Re-read per attempt rather than captured once. A turn can outlive its
		-- access token, and a 401 retry is only worth making with a new one —
		-- getAccessToken refreshes when it is close to expiry, and `fail` forces
		-- one outright when the server has already rejected it.
		local accessToken, attemptTokenErr = OAuth.getAccessToken()
		if not accessToken then
			if callbacks.onError then callbacks.onError("Auth: " .. tostring(attemptTokenErr)) end
			return
		end
		-- InactivityTimeout is raised by Roblox, not by the API, and it says nothing
		-- about WHERE the silence was. The two cases have different causes and
		-- different fixes: before the first byte is the server reprocessing an
		-- uncached prefix, which is a caching problem; after it is a stall mid-answer,
		-- which is not. Wall clock, because the thing being measured is a network
		-- wait, and seconds are enough against a window Roblox puts near 20.
		startedAt = os.time()
		firstByteAt = nil

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
			-- Not routed through `fail`: there is no stream to close and no status to
			-- classify. Six clients may exist at once, so this is also what a leak
			-- from an earlier turn eventually looks like.
			if callbacks.onError then callbacks.onError("Failed to create stream client: " .. tostring(err)) end
			return
		end

		-- Assign to the forward-declared `stream` local (so processSSEEvents can see it)
		stream = client

		stream.Opened:Connect(function(statusCode: number, headers: string)
			if myGeneration ~= generation then return end
			-- Kept whatever the status: a 429 carries retry-after here, and the body
			-- explaining it arrives separately through MessageReceived.
			responseHeaders = headers
			responseStatus = statusCode
		end)

		stream.MessageReceived:Connect(function(message: string)
			if handle.cancelled or dead or myGeneration ~= generation then return end
			if firstByteAt == nil then firstByteAt = os.time() end
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
					-- The body is passed on so an overloaded_error is recognised even
					-- when the status never made it through.
					-- responseStatus, not nil: this is the 401/429 path, and every
					-- decision fail makes about those keys off the number.
					fail(responseStatus, message, msg)
				else
					-- Could be a partial SSE event, buffer it
					processSSEEvents(message)
				end
			end
		end)

		stream.Error:Connect(function(statusCode: number, errorMessage: string)
			-- An abandoned socket erroring on its way out must not be allowed to
			-- fail the attempt that replaced it.
			if myGeneration ~= generation then return end
			-- Which side of the first byte this died on, and how long it took to get
			-- there. Spelled out in the message itself rather than logged separately,
			-- because the person who sees this is the one who has to decide whether
			-- the history is too big or the connection is bad.
			local now = os.time()
			local where: string
			if firstByteAt == nil then
				where = string.format(
					"silent for %ds, no first byte — the prefix was almost certainly uncached and the server was still reading it",
					now - startedAt)
			else
				where = string.format(
					"first byte after %ds, then stalled %ds mid-answer",
					(firstByteAt :: number) - startedAt, now - (firstByteAt :: number))
			end
			-- errorMessage carries the HttpError name, which is what isRetryable
			-- matches InactivityTimeout on; the status here is 200 for a stream that
			-- opened cleanly and then went quiet.
			fail(statusCode, errorMessage,
				string.format("Stream error (HTTP %s): %s — %s",
					tostring(statusCode), tostring(errorMessage), where))
		end)

		stream.Closed:Connect(function()
			-- Stream ended. If onComplete hasn't fired, this was unexpected.
		end)
	end

	start()
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

	-- Retry classification. Each of these has a way of being wrong that costs
	-- something real: refusing a 529 wastes the turn, retrying a 400 wastes the
	-- user's time twice, and missing the body-matched overload means the one
	-- error that arrives inside a 200 response is never caught.
	if not isRetryable(429, nil) then return false, "429 is not being retried" end
	if not isRetryable(529, nil) then return false, "529 is not being retried" end
	if not isRetryable(nil, '{"type":"error","error":{"type":"overloaded_error"}}') then
		return false, "overloaded_error in a 200 stream is not being retried"
	end
	if not isRetryable(200, "HttpError: InactivityTimeout") then
		return false, "InactivityTimeout is not being retried"
	end
	if isRetryable(400, "invalid_request_error") then
		return false, "a 400 is being retried; it cannot succeed"
	end
	if isRetryable(401, nil) then return false, "an auth failure is being retried" end
	if not isOverload(nil, '{"type":"overloaded_error"}') then
		return false, "overload not detected from the body, so it gets the wrong budget"
	end
	if isOverload(429, nil) then return false, "a 429 is being counted against the 529 budget" end

	-- retry-after wins when it is the longer wait, and does NOT shorten a backoff
	-- that has already grown past it — the second half is the part the leaked
	-- tree gets wrong, so it is worth pinning.
	if retryDelay(1, 7) ~= 7 then return false, "retry-after was not honoured" end
	if retryDelay(8, 1) <= 1 then
		return false, "a short retry-after shortened a long backoff"
	end
	-- Doubling, and the jitter only ever adds.
	for attempt = 1, 8 do
		local base = math.min(BASE_DELAY * 2 ^ (attempt - 1), MAX_DELAY)
		local delay = retryDelay(attempt, nil)
		if delay < base or delay > base * 1.25 then
			return false, string.format("retryDelay(%d) = %.3f, outside [%.3f, %.3f]",
				attempt, delay, base, base * 1.25)
		end
	end
	if retryDelay(99, nil) > MAX_DELAY * 1.25 then
		return false, "backoff is not capped"
	end

	if retryAfterSeconds("content-type: application/json\r\nretry-after: 12\r\n") ~= 12 then
		return false, "retry-after header not parsed"
	end
	if retryAfterSeconds("Retry-After: 3") ~= 3 then
		return false, "retry-after header is case-sensitive"
	end
	if retryAfterSeconds("content-type: application/json") ~= nil then
		return false, "retry-after invented from headers that carry none"
	end

	if not needsTokenRefresh(401, nil) then return false, "401 does not trigger a token refresh" end
	if not needsTokenRefresh(403, '{"error":{"message":"OAuth token has been revoked"}}') then
		return false, "a revoked-token 403 does not trigger a refresh"
	end
	if needsTokenRefresh(403, '{"error":{"message":"permission denied"}}') then
		return false, "a plain permission 403 is being answered with a token refresh"
	end
	if needsTokenRefresh(429, nil) then return false, "a rate limit is being treated as an auth failure" end
	if not isRetryable(500, nil) then return false, "500 api_error is not being retried" end
	if not isRetryable(503, nil) then return false, "503 is not being retried" end
	if isRetryable(404, nil) then return false, "404 is being retried" end
	if isRetryable(413, nil) then return false, "413 request_too_large is being retried" end

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
	webSearchTool = webSearchTool,
	DEFAULT_MODEL = DEFAULT_MODEL,
	_MESSAGES_URL = MESSAGES_URL,
	_ANTHROPIC_VERSION = ANTHROPIC_VERSION,
	_ANTHROPIC_BETA = ANTHROPIC_BETA,
	_CLAUDE_CODE_IDENTITY = CLAUDE_CODE_IDENTITY,
}
