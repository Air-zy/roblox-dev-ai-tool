--!optimize 2
-- Nvidia.luau: NVIDIA NIM chat/completions client, one request, SSE back.
--
-- The point of this provider is a second free tier with a different roster.
-- OpenRouter's free models are capped at 50 requests a DAY across all of them,
-- and an agent turn is many requests rather than one, so that cap arrives fast
-- here. NVIDIA's hosted endpoint is about 40 a MINUTE, per model, and fronts
-- Nemotron, Kimi, DeepSeek and gpt-oss.
--
-- The wire is OpenAI chat/completions, so the translation is OpenRouter.luau's
-- and the header there is the one to read for how a conversation is flattened
-- and rebuilt. What follows is only where this endpoint differs from that one,
-- and every entry is something that breaks the harness if it is missed.
--
--   * max_tokens DEFAULTS TO 2048. OpenRouter.luau deliberately omits the field
--     because it defaults to the model's own ceiling; that reasoning does not
--     carry over, and omitting it here truncates almost every turn.
--   * There are TWO reasoning switches and they are not interchangeable:
--     `reasoning_effort` at the gateway, and `chat_template_kwargs` whose KEY
--     NAMES differ by model family. Which one a model takes is a property of the
--     model, so it lives on the model's row in CURATED.
--   * Nemotron needs `force_nonempty_content` for tool use with thinking on.
--     NVIDIA documents it as required for coding agents, and without it a
--     reasoning turn can come back as plain text with finish_reason "stop" where
--     the tool_calls should have been — which in a harness that is nothing but
--     tool calls means the turn silently does nothing.
--   * `stream_options.include_usage` is the only way a streamed response reports
--     usage at all, and what it reports has no cache breakdown.
--   * Reasoning streams as delta.reasoning_content, not delta.reasoning, and
--     there is no reasoning_details equivalent. It is NOT sent back: unlike an
--     Anthropic signature there is no documented field to replay it into. Kept
--     in a thinking block so the UI can show it and Agent can keep it, dropped
--     at the wire's edge.
--   * No prompt caching of any kind, no server-side web search, and no
--     keepalive comments during a queue wait — where OpenRouter's
--     ": OPENROUTER PROCESSING" is what stops Roblox killing a slow stream,
--     this endpoint sends nothing and a long queue looks like an
--     InactivityTimeout.
--
-- Reference: https://docs.api.nvidia.com/nim/reference/llm-apis

local HttpService = game:GetService("HttpService")
local warn = warn

local Stream = require(script.Parent:WaitForChild("Stream"))
local ToolJson = require(script.Parent:WaitForChild("ToolJson"))

local Nvidia = {}

-- Forward-declared: Initialize schedules it, and it is defined further down.
local refreshModels: () -> (boolean, string?)

local Auth: any = nil     -- set via Initialize
local plugin: any = nil   -- set via Initialize, for the model-list cache

local COMPLETIONS_URL = "https://integrate.api.nvidia.com/v1/chat/completions"
local MODELS_URL = "https://integrate.api.nvidia.com/v1/models"

local KEY_MODEL_CACHE = "nvidia_models"
local KEY_MODEL_CACHE_AT = "nvidia_models_at"
local MODEL_CACHE_MAX_AGE = 24 * 3600

-- The gateway default is 2048, which is a paragraph. Sent on every request for
-- an id CURATED has never heard of.
--
-- ponytail: one number for every unlisted model. The ceiling is a model whose
-- own output cap is lower, which answers 400; the upgrade path is a maxOutput on
-- that model's row below.
local DEFAULT_MAX_TOKENS = 16384

-- The repo has five effort levels and NVIDIA has six, and they are not the same
-- six: `xhigh` is not a value this API knows, and sending it fails the request
-- rather than being clamped.
local EFFORT_MAP: { [string]: string } = { xhigh = "high" }

-- Hand-written, and it WILL go stale — GET /v1/models returns an id, an owner
-- and nothing else: no context length, no pricing, no capability flags, so
-- there is nothing here to derive. Every figure below is off that model's own
-- page on build.nvidia.com.
--
-- `context` is omitted rather than guessed where there is no published number.
-- contextWindow then returns nil and the settings panel draws no bar, which is
-- the honest reading; a made-up denominator is a confidently wrong one.
--
-- Two models are deliberately NOT here. minimaxai/minimax-m3 and z-ai/glm-5.2
-- both have reports of tool-call arguments never arriving as delta fragments —
-- the text streams, then the gateway goes quiet for up to 300 seconds while the
-- call is assembled and closes with no finish_reason and no [DONE]. On this host
-- that silence is an InactivityTimeout, and a harness whose every capability is
-- a tool call cannot use a model that does that. Both stay reachable by name
-- through /model for anyone who wants to try them anyway.
local CURATED: { any } = {
	{
		id = "nvidia/nemotron-3-super-120b-a12b",
		label = "NVIDIA: Nemotron 3 Super",
		name = "Nemotron 3 Super",
		hint = "256k · reasoning",
		-- Documented as "up to 1M" with a 256k default; which one the HOSTED
		-- endpoint runs is not published. The smaller number on purpose: an
		-- undersized window fills the context bar early and clears sooner than
		-- it has to, which is the safe direction to be wrong in.
		context = 262144,
		maxOutput = 16000,
		thinking = "nemotron",
	},
	{
		id = "moonshotai/kimi-k3",
		label = "Moonshot: Kimi K3",
		name = "Kimi K3",
		hint = "1M · reasoning",
		context = 1048576,
		effort = true,
	},
	{
		id = "nvidia/nemotron-3-ultra-550b-a55b",
		label = "NVIDIA: Nemotron 3 Ultra",
		name = "Nemotron 3 Ultra",
		hint = "1M · reasoning",
		context = 1048576,
		maxOutput = 16000,
		thinking = "nemotron",
	},
	{
		id = "openai/gpt-oss-20b",
		label = "OpenAI: gpt-oss 20B",
		name = "gpt-oss 20B",
		hint = "131k · reasoning",
		context = 131072,
		effort = true,
	},
	{
		-- Listed because it is one of the strongest models on the endpoint, and
		-- flagged in the hint because of a standing report that its tool calls do
		-- not always normalise into OpenAI-shaped delta.tool_calls here. When that
		-- happens the model narrates what it would have done instead of doing it,
		-- which is a recognisable failure rather than a confusing one.
		id = "deepseek-ai/deepseek-v4-pro-0813",
		label = "DeepSeek: V4 Pro",
		name = "DeepSeek V4 Pro",
		hint = "1M · tools flaky",
		context = 1048576,
		effort = true,
	},
}

Nvidia.MODELS = CURATED
Nvidia.DEFAULT_MODEL = "nvidia/nemotron-3-super-120b-a12b"

-- The curated row for an id, or nil for one typed in by hand. nil is the whole
-- point: it is what stops a reasoning field being sent to a model this file
-- knows nothing about.
local function capsFor(model: string): any?
	for _, entry in ipairs(CURATED) do
		if entry.id == model then return entry end
	end
	return nil
end

-- Model list
-- "mistralai/mistral-large" -> "mistral-large". The vendor is already in the id,
-- which the picker also searches, and the chip at the corner of the input row
-- has room for about this much.
local function shortName(id: string): string
	return id:match("^[^/]+/(.+)$") or id
end

-- Curated first, then everything else the endpoint lists. main.luau renders
-- MODELS in order and draws only the first few matches before saying how many
-- more there are, so the tail costs nothing until somebody types.
local function applyTail(ids: { string })
	local out: { any } = {}
	local seen: { [string]: boolean } = {}
	for _, entry in ipairs(CURATED) do
		out[#out + 1] = entry
		seen[entry.id] = true
	end
	for _, id in ipairs(ids) do
		if type(id) == "string" and id ~= "" and not seen[id] then
			seen[id] = true
			-- No `context`, deliberately: nothing published one. No `hint` either,
			-- because there is nothing true to put in it.
			out[#out + 1] = { id = id, label = id, name = shortName(id) }
		end
	end
	Nvidia.MODELS = out
end

local function Initialize(authModule: any, pluginRef: any)
	Auth = authModule
	plugin = pluginRef

	-- Warm from the cache immediately, then refresh in the background if it is
	-- stale. Nothing waits on the network to draw a picker.
	if plugin then
		local cached = plugin:GetSetting(KEY_MODEL_CACHE)
		if type(cached) == "string" and cached ~= "" then
			local ok, decoded = pcall(function() return HttpService:JSONDecode(cached) end)
			if ok and type(decoded) == "table" and #decoded > 0 then
				applyTail(decoded)
			end
		end
		local at = plugin:GetSetting(KEY_MODEL_CACHE_AT)
		if type(at) ~= "number" or os.time() - at > MODEL_CACHE_MAX_AGE then
			task.spawn(refreshModels)
		end
	end
end

-- Fetches the catalogue and keeps the ids. Only the ids: the response carries an
-- owner and a timestamp and nothing else worth having, so unlike OpenRouter
-- there is no filtering to do here — nothing in it says which models can call a
-- tool, and the embedders and rerankers in the list are left in rather than
-- pattern-matched out. A guessed filter rots as NVIDIA adds families, and
-- picking one of them is a mistake the first error message explains.
--
-- Sent WITHOUT an Authorization header, which is not an oversight: this endpoint
-- is public, so the picker fills before anyone has logged in.
--
-- The cache holds the fetched ids alone, not the assembled list. A cache holding
-- curated rows would go on serving an old build's numbers after this file's were
-- corrected.
--
-- Yields; call it from a task.spawn.
function refreshModels(): (boolean, string?)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = MODELS_URL,
			Method = "GET",
			Headers = { ["accept"] = "application/json" },
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
	if type(data) ~= "table" then
		return false, "model list: no data array"
	end

	local ids: { string } = {}
	for _, entry in ipairs(data) do
		if type(entry) == "table" and type(entry.id) == "string" then
			ids[#ids + 1] = entry.id
		end
	end
	if #ids == 0 then
		-- Never replace a working list with an empty one.
		return false, "model list: no ids in the response"
	end
	table.sort(ids)

	applyTail(ids)
	if plugin then
		pcall(function()
			plugin:SetSetting(KEY_MODEL_CACHE, HttpService:JSONEncode(ids))
			plugin:SetSetting(KEY_MODEL_CACHE_AT, os.time())
		end)
	end
	return true
end

-- Any `vendor/model` slug is a real id here. The catalogue is not even complete
-- — models are reachable on this endpoint that GET /v1/models does not list — so
-- this lets `/model anything/else` through untouched.
local function acceptsModelId(id: string): boolean
	return id:find("/", 1, true) ~= nil
end

-- Outbound
local function toolArguments(input: any): string
	-- An empty Lua table encodes as `[]`, and `arguments` must be a JSON OBJECT.
	if type(input) ~= "table" or next(input) == nil then return "{}" end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(input) end)
	return if ok then encoded else "{}"
end

local function resultText(content: any): string
	if type(content) == "string" then return content end
	if type(content) == "table" then
		-- A tool_result whose content is a block list. Ours are always strings,
		-- but a restored session could hold either.
		local parts: { string } = {}
		for _, block in ipairs(content) do
			if type(block) == "table" and type(block.text) == "string" then
				parts[#parts + 1] = block.text
			elseif type(block) == "string" then
				parts[#parts + 1] = block
			end
		end
		return table.concat(parts, "\n")
	end
	return tostring(content)
end

-- The whole conversation, flattened. Returns a NEW array: `messages` is the live
-- table Agent appends to and Sessions persists, and writing request shaping into
-- it would leak onto the screen and into storage.
local function toChatMessages(system: string?, messages: { any }): { any }
	local out: { any } = {}

	if system and system ~= "" then
		out[#out + 1] = { role = "system", content = system }
	end

	for _, message in ipairs(messages) do
		local content = message.content

		if type(content) == "string" then
			out[#out + 1] = { role = message.role, content = content }

		elseif type(content) == "table" and message.role == "user" then
			-- A tool_result batch. Anthropic packs them into one user message;
			-- here each one is its own message with the id it answers. Emitted
			-- before any loose text so they stay adjacent to the calls above.
			local texts: { string } = {}
			for _, block in ipairs(content) do
				if block.type == "tool_result" then
					out[#out + 1] = {
						role = "tool",
						tool_call_id = block.tool_use_id,
						content = resultText(block.content),
					}
				elseif block.type == "text" and block.text then
					texts[#texts + 1] = block.text
				end
			end
			if #texts > 0 then
				out[#out + 1] = { role = "user", content = table.concat(texts, "\n") }
			end

		elseif type(content) == "table" then
			local texts: { string } = {}
			local toolCalls: { any } = {}

			for _, block in ipairs(content) do
				if block.type == "text" and block.text then
					texts[#texts + 1] = block.text
				elseif block.type == "tool_use" then
					toolCalls[#toolCalls + 1] = {
						id = block.id,
						type = "function",
						["function"] = { name = block.name, arguments = toolArguments(block.input) },
					}
				end
				-- A thinking block is dropped here on purpose. This endpoint sends
				-- reasoning OUT as `reasoning_content` but documents no field to
				-- send it back IN, unlike an Anthropic signature, which has to be
				-- replayed verbatim or the request is rejected. The block still
				-- exists in the conversation — the UI renders it and Sessions
				-- stores it — it just does not reach the wire.
			end

			local assistant: { [string]: any } = { role = "assistant" }
			assistant.content = if #texts > 0 then table.concat(texts, "\n") else ""
			if #toolCalls > 0 then assistant.tool_calls = toolCalls end
			out[#out + 1] = assistant
		end
	end

	return out
end

local function toChatTools(tools: { any }?): { any }?
	if not tools or #tools == 0 then return nil end
	local out: { any } = {}
	for _, tool in ipairs(tools) do
		-- Anything without a name is a server tool from the other provider; there
		-- is nothing to send for it here.
		if tool.name then
			out[#out + 1] = {
				type = "function",
				["function"] = {
					name = tool.name,
					description = tool.description,
					-- eager_input_streaming is deliberately dropped: it is an
					-- Anthropic tool-definition flag with no counterpart here.
					parameters = tool.input_schema,
				},
			}
		end
	end
	return if #out > 0 then out else nil
end

local function maxTokensFor(model: string): number
	local caps = capsFor(model)
	return (caps and caps.maxOutput) or DEFAULT_MAX_TOKENS
end

-- Which reasoning switch this model takes, if any, applied to the body in place.
-- An id with no curated row gets NEITHER field, and that is the point: a
-- parameter the backend does not recognise fails the whole request rather than
-- being ignored, so silence is the only safe default for a model this file has
-- never heard of.
local function applyReasoning(body: { [string]: any }, model: string, effort: string?)
	local caps = capsFor(model)
	if not caps then return end

	if caps.effort then
		if effort and effort ~= "" then
			body.reasoning_effort = EFFORT_MAP[effort] or effort
		end
	elseif caps.thinking == "nemotron" then
		local kwargs: { [string]: any } = {
			enable_thinking = true,
			-- Not optional. NVIDIA documents this as required for coding agents:
			-- without it a reasoning turn can come back as plain content with
			-- finish_reason "stop" where the tool_calls belonged, and a harness
			-- that is nothing but tool calls then does nothing at all.
			force_nonempty_content = true,
		}
		-- The family's own name for a cheaper think. There is no equivalent for
		-- the levels above, which all mean "think normally" here.
		if effort == "low" then kwargs.low_effort = true end
		body.chat_template_kwargs = kwargs
	end
end

-- Rebased, and this is the subtle one. Anthropic reports input_tokens EXCLUDING
-- what it read from cache; OpenAI-shaped usage reports prompt_tokens INCLUDING
-- it. Agent adds input + cache_read + cache_creation to get the turn's true
-- input, so handing it prompt_tokens raw would double-count every cached token.
--
-- This endpoint caches nothing and reports no breakdown, so both cache fields
-- fall to zero and input_tokens is prompt_tokens — which is correct. The
-- arithmetic is kept rather than simplified away so that the day a
-- prompt_tokens_details appears, the number does not quietly go wrong.
local function rebaseUsage(u: any): any?
	if type(u) ~= "table" then return nil end
	local details = u.prompt_tokens_details
	local cached = (type(details) == "table" and details.cached_tokens) or u.cached_tokens or 0
	local written = u.cache_write_tokens or 0
	local prompt = u.prompt_tokens or 0
	return {
		input_tokens = math.max(prompt - cached - written, 0),
		cache_read_input_tokens = cached,
		cache_creation_input_tokens = written,
		output_tokens = u.completion_tokens or 0,
	}
end

-- streamMessage
-- Same signature and the same callbacks as Anthropic.streamMessage, because
-- Agent drives every provider through one code path.
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
		onToolUseStart: ((string?, string) -> ())?,
		onToolInput: ((string?, string) -> ())?,
		onServerToolUse: ((string, string?, any) -> ())?,
		onServerToolResult: ((string, string?, any) -> ())?,
		onComplete: ((any) -> ())?,
		onError: ((string, string?) -> ())?,
		onRetry: ((string, number, number, number) -> ())?,
	}): Stream.Handle
	local function noopHandle()
		return { cancelled = true, cancel = function() end }
	end

	if not Auth then
		if callbacks.onError then callbacks.onError("NVIDIA module not initialized.") end
		return noopHandle()
	end
	if not args or type(args.messages) ~= "table" or #args.messages == 0 then
		if callbacks.onError then callbacks.onError("messages array is required and must be non-empty.") end
		return noopHandle()
	end

	local firstKey, keyErr = Auth.getAccessToken()
	if not firstKey then
		if callbacks.onError then callbacks.onError("Auth: " .. tostring(keyErr)) end
		return noopHandle()
	end

	local model = args.model or Nvidia.DEFAULT_MODEL

	local bodyTable: { [string]: any } = {
		model = model,
		stream = true,
		messages = toChatMessages(args.system, args.messages),
		-- Not optional here, unlike every other provider in this folder: the
		-- gateway default is 2048 tokens, which truncates a turn mid-tool-call.
		max_tokens = args.maxTokens or maxTokensFor(model),
		-- The only way a streamed response reports usage at all. Without it the
		-- token counters and the context bar read zero forever.
		stream_options = { include_usage = true },
	}

	applyReasoning(bodyTable, model, args.effort)

	local tools = toChatTools(args.tools)
	if tools then
		bodyTable.tools = tools
		bodyTable.tool_choice = "auto"
	end

	-- args.webSearch is ignored: this endpoint has no server-side search, and
	-- Agent passes a COUNT precisely so each provider can decide it has none.

	local bodyStr = HttpService:JSONEncode(bodyTable)

	-- Accumulators, rebuilt per attempt by `reset` below.
	local textAcc = ""
	local reasonAcc = ""
	local toolAcc: { any } = {}
	local toolCount = 0
	local usage: any = nil
	local stopReason: string? = nil
	local completed = false

	-- Normalised so Agent's one diagnostic that reads this ("stop_reason: %s"
	-- when a tool input will not parse) says something a person recognises.
	local FINISH = {
		tool_calls = "tool_use",
		stop = "end_turn",
		length = "max_tokens",
	}

	local function assemble(): { any }
		local blocks: { any } = {}
		if reasonAcc ~= "" then
			-- Agent drops a thinking block with no signature, so there is always
			-- one. It holds the text and nothing else — this provider has no
			-- opaque blob to carry, because the reasoning never goes back out.
			blocks[#blocks + 1] = {
				type = "thinking",
				thinking = reasonAcc,
				signature = HttpService:JSONEncode({ t = reasonAcc }),
			}
		end
		if textAcc ~= "" then
			blocks[#blocks + 1] = { type = "text", text = textAcc }
		end
		for i = 1, toolCount do
			local slot = toolAcc[i]
			if slot and slot.name then
				local parsed, repaired = ToolJson.decode(slot.args)
				if repaired then
					warn(string.format(
						"[agent] %s: repaired unescaped control characters in tool input",
						tostring(slot.name)))
				end
				blocks[#blocks + 1] = {
					type = "tool_use",
					id = slot.id,
					name = slot.name,
					input = slot.args,
					inputParsed = parsed,
				}
			end
		end
		return blocks
	end

	local function complete(ctrl: Stream.Ctrl)
		if completed then return end
		completed = true
		local blocks = assemble()
		ctrl.finish(function()
			if callbacks.onComplete then
				callbacks.onComplete({
					ok = true,
					text = if textAcc ~= "" then textAcc else nil,
					thinking = if reasonAcc ~= "" then reasonAcc else nil,
					usage = usage,
					stopReason = stopReason,
					contentBlocks = blocks,
				})
			end
		end)
	end

	local function readToolCalls(calls: any, ctrl: Stream.Ctrl)
		for _, call in ipairs(calls) do
			-- `index` identifies the call across chunks; id and name arrive on the
			-- first fragment for it and the arguments dribble in after — on the
			-- models that stream them at all. See the header.
			local slot = toolAcc[(call.index or 0) + 1]
			if not slot then
				slot = { id = nil, name = nil, args = "", announced = false }
				toolAcc[(call.index or 0) + 1] = slot
				toolCount = math.max(toolCount, (call.index or 0) + 1)
			end
			if type(call.id) == "string" and call.id ~= "" then slot.id = call.id end

			local fn = call["function"]
			local fragment: string? = nil
			if type(fn) == "table" then
				if type(fn.name) == "string" and fn.name ~= "" then slot.name = fn.name end
				if type(fn.arguments) == "string" and fn.arguments ~= "" then
					slot.args ..= fn.arguments
					fragment = fn.arguments
				end
			end

			-- Announced as soon as the name is known, which is what puts the block
			-- on screen while the arguments are still being written.
			if not slot.announced and slot.name then
				slot.announced = true
				ctrl.emitted()
				if callbacks.onToolUseStart then
					callbacks.onToolUseStart(slot.id, slot.name)
				end
			end
			if fragment and slot.announced and callbacks.onToolInput then
				callbacks.onToolInput(slot.id, fragment)
			end
		end
	end

	local function onFrame(frame: string, ctrl: Stream.Ctrl)
		for line in frame:gmatch("[^\r\n]+") do
			-- SSE comments. This endpoint does not appear to send any, which is
			-- itself worth knowing: a keepalive is what stops Roblox killing a
			-- stream that is only queued rather than stalled, and there is none
			-- here. Skipped anyway, in case that changes.
			if line:sub(1, 1) ~= ":" then
				local data = line:match("^data:%s*(.+)$")
				if data == "[DONE]" then
					complete(ctrl)
					return
				elseif data then
					local parsed
					if not pcall(function() parsed = HttpService:JSONDecode(data) end) then
						-- Unreadable frame. One frame is one call, so there is
						-- nothing to continue past.
						return
					end
					local chunk = parsed :: any

					-- A mid-stream error arrives as an ordinary chunk with an error
					-- object on it, inside a response whose HTTP status was 200.
					if chunk.error then
						local err = chunk.error
						ctrl.fail(nil, data, string.format("stream error — %s",
							tostring(err.message or err.type or "unknown")))
						return
					end

					if chunk.usage then usage = rebaseUsage(chunk.usage) or usage end

					-- The usage chunk carries an EMPTY choices array, so this guard
					-- is load-bearing rather than defensive.
					local choice = chunk.choices and chunk.choices[1]
					if choice then
						if choice.finish_reason then
							stopReason = FINISH[choice.finish_reason] or choice.finish_reason
						end
						local delta = choice.delta
						if type(delta) == "table" then
							if type(delta.content) == "string" and delta.content ~= "" then
								ctrl.emitted()
								textAcc ..= delta.content
								if callbacks.onText then callbacks.onText(delta.content) end
							end
							-- reasoning_content, not OpenRouter's `reasoning`.
							if type(delta.reasoning_content) == "string" and delta.reasoning_content ~= "" then
								ctrl.emitted()
								reasonAcc ..= delta.reasoning_content
								if callbacks.onThinking then callbacks.onThinking(delta.reasoning_content) end
							end
							if type(delta.tool_calls) == "table" then
								readToolCalls(delta.tool_calls, ctrl)
							end
						end
					end
				end
			end
		end
	end

	return Stream.open({
		request = function()
			local key, attemptErr = Auth.getAccessToken()
			if not key then
				return nil, "Auth: " .. tostring(attemptErr)
			end
			return {
				url = COMPLETIONS_URL,
				headers = {
					["Authorization"] = "Bearer " .. (key :: string),
					["content-type"] = "application/json",
					["accept"] = "text/event-stream",
				},
				body = bodyStr,
			}
		end,

		reset = function()
			textAcc = ""
			reasonAcc = ""
			toolAcc = {}
			toolCount = 0
			usage = nil
			stopReason = nil
			completed = false
		end,

		frame = onFrame,

		-- A clean close with no [DONE]. Rare in principle and not rare here: the
		-- gateway is reported to end a long tool-call assembly exactly this way.
		-- Anything already accumulated is delivered rather than thrown away.
		closed = function(ctrl: Stream.Ctrl)
			if stopReason or textAcc ~= "" or toolCount > 0 then
				complete(ctrl)
			end
		end,

		partial = function(): string?
			return if textAcc ~= "" then textAcc else nil
		end,

		-- Both of these say something the raw body does not. NVIDIA answers a bad
		-- key with "Authorization failed" and nothing about why it might have
		-- stopped working, and a rate limit with no headers at all.
		explain = function(status: number?, _body: string?): string?
			if status == 401 or status == 403 then
				return "NVIDIA rejected the key. Personal keys EXPIRE — six months, unless the "
					.. "key was created as \"Never Expire\" — so one that worked last month can "
					.. "stop with no warning. Generate another at "
					.. tostring(Auth and Auth.API_KEYS_URL) .. " and paste it with /code."
			end
			if status == 429 then
				return string.format(
					"Rate limited. The free tier is about %d requests a minute PER MODEL, and is "
					.. "documented as a best-effort ceiling rather than a guarantee. An agent turn "
					.. "is many requests rather than one, so this arrives sooner here than it "
					.. "would in a chat window; another model has its own budget.",
					(Auth and Auth.FREE_RPM) or 40)
			end
			return nil
		end,

		-- No refresh hook: a personal key does not refresh, so a 401 means it was
		-- revoked or has aged out and asking again with the same one cannot help.
	}, {
		onError = callbacks.onError,
		onRetry = callbacks.onRetry,
	})
end

-- Self-test
-- Translation is most of this file and every way it can be wrong is quiet: a
-- dropped tool_call_id desyncs the next turn, a reasoning field sent to a model
-- that does not take one fails the request, and a missing max_tokens truncates
-- an answer at 2048 behind a plausible-looking finish_reason.
local function selfTest(): (boolean, string?)
	local jsonOk, jsonErr = ToolJson.selfTest()
	if not jsonOk then return false, "ToolJson: " .. tostring(jsonErr) end

	-- A conversation exercising every block shape that reaches the wire.
	local conversation = {
		{ role = "user", content = "hello" },
		{ role = "assistant", content = {
			{ type = "thinking", thinking = "a summary", signature = '{"t":"a summary"}' },
			{ type = "text", text = "listing" },
			{ type = "tool_use", id = "call_1", name = "bash", input = { command = "ls" } },
		} },
		{ role = "user", content = {
			{ type = "tool_result", tool_use_id = "call_1", content = "Baseplate" },
		} },
	}
	local before = HttpService:JSONEncode(conversation)
	local out = toChatMessages("be brief", conversation)

	if HttpService:JSONEncode(conversation) ~= before then
		return false, "toChatMessages mutated the caller's conversation"
	end
	-- system, user, assistant, tool
	if #out ~= 4 then
		return false, string.format("expected 4 wire messages, got %d", #out)
	end
	if out[1].role ~= "system" or out[1].content ~= "be brief" then
		return false, "the system prompt did not become a system message"
	end
	if out[3].role ~= "assistant" or out[3].content ~= "listing" then
		return false, "assistant text did not flatten"
	end
	if not out[3].tool_calls or out[3].tool_calls[1].id ~= "call_1"
		or out[3].tool_calls[1]["function"].name ~= "bash" then
		return false, "a tool_use block did not become a tool_call"
	end
	if out[3].tool_calls[1]["function"].arguments ~= '{"command":"ls"}' then
		return false, "tool arguments did not encode as a JSON object string"
	end
	-- The one deliberate loss. There is no field to replay reasoning into here,
	-- and inventing one fails the request.
	if (out[3] :: any).reasoning ~= nil or (out[3] :: any).reasoning_content ~= nil then
		return false, "reasoning was sent back to an endpoint that does not take it"
	end
	-- The batch-to-one-message-each fan-out, and the id that pairs them.
	if out[4].role ~= "tool" or out[4].tool_call_id ~= "call_1" or out[4].content ~= "Baseplate" then
		return false, "a tool_result did not become a tool message"
	end

	-- An empty tool input must encode as an object. `{}` in Lua is an array to
	-- the encoder, and `arguments: []` is rejected.
	if toolArguments({}) ~= "{}" then
		return false, "an empty tool input did not encode as an object"
	end

	-- max_tokens. The gateway default is 2048, so "absent" and "2048" are the two
	-- ways to silently truncate every turn.
	if maxTokensFor("nvidia/nemotron-3-super-120b-a12b") ~= 16000 then
		return false, "a curated maxOutput was not used"
	end
	if maxTokensFor("someone/unlisted-model") ~= DEFAULT_MAX_TOKENS then
		return false, "an unlisted model did not fall back to DEFAULT_MAX_TOKENS"
	end
	if DEFAULT_MAX_TOKENS <= 2048 then
		return false, "DEFAULT_MAX_TOKENS is no better than the gateway default"
	end

	-- The two reasoning switches, and the third case that matters most: neither.
	local effortBody: { [string]: any } = {}
	applyReasoning(effortBody, "moonshotai/kimi-k3", "max")
	if effortBody.reasoning_effort ~= "max" or effortBody.chat_template_kwargs ~= nil then
		return false, "an effort model did not get reasoning_effort alone"
	end

	local xhighBody: { [string]: any } = {}
	applyReasoning(xhighBody, "moonshotai/kimi-k3", "xhigh")
	if xhighBody.reasoning_effort ~= "high" then
		return false, "xhigh was not mapped to a value this API knows"
	end

	local thinkBody: { [string]: any } = {}
	applyReasoning(thinkBody, "nvidia/nemotron-3-super-120b-a12b", "high")
	local kwargs = thinkBody.chat_template_kwargs
	if type(kwargs) ~= "table" or kwargs.enable_thinking ~= true then
		return false, "a thinking model did not get chat_template_kwargs"
	end
	if kwargs.force_nonempty_content ~= true then
		return false, "force_nonempty_content missing — tool calls will come back as prose"
	end
	if thinkBody.reasoning_effort ~= nil then
		return false, "a thinking model was also sent reasoning_effort"
	end
	if kwargs.low_effort ~= nil then
		return false, "low_effort was set at an effort level that is not low"
	end
	local lowBody: { [string]: any } = {}
	applyReasoning(lowBody, "nvidia/nemotron-3-super-120b-a12b", "low")
	if (lowBody.chat_template_kwargs :: any).low_effort ~= true then
		return false, "low effort did not reach the chat template"
	end

	local unknownBody: { [string]: any } = {}
	applyReasoning(unknownBody, "someone/unlisted-model", "max")
	if next(unknownBody) ~= nil then
		return false, "a reasoning field was sent to a model with no curated row"
	end

	-- Usage. This endpoint reports no cache breakdown, so the rebasing must leave
	-- prompt_tokens alone rather than subtracting a nil into zero.
	local u = rebaseUsage({ prompt_tokens = 120, completion_tokens = 30, total_tokens = 150 })
	if not u or u.input_tokens ~= 120 or u.output_tokens ~= 30 then
		return false, "NIM-shaped usage did not rebase"
	end
	if u.cache_read_input_tokens ~= 0 or u.cache_creation_input_tokens ~= 0 then
		return false, "cache fields were invented for an endpoint that does not cache"
	end

	-- Tool definitions: input_schema becomes parameters, and the Anthropic-only
	-- streaming flag does not ride along.
	local wireTools = toChatTools({
		{ name = "bash", description = "run", input_schema = { type = "object" }, eager_input_streaming = true },
	})
	if not wireTools or wireTools[1].type ~= "function"
		or wireTools[1]["function"].name ~= "bash"
		or wireTools[1]["function"].parameters == nil then
		return false, "a tool definition did not convert"
	end
	if (wireTools[1] :: any).eager_input_streaming ~= nil
		or (wireTools[1]["function"] :: any).eager_input_streaming ~= nil then
		return false, "an Anthropic-only tool flag was sent to NVIDIA"
	end

	-- Model list assembly: curated first, fetched tail after, no duplicates, and
	-- the tail carries no context so no bar is drawn for it.
	local restore = Nvidia.MODELS
	applyTail({ "mistralai/mistral-large", "nvidia/nemotron-3-super-120b-a12b" })
	local assembled = Nvidia.MODELS
	if #assembled ~= #CURATED + 1 then
		return false, "the fetched tail did not deduplicate against the curated rows"
	end
	if assembled[1].id ~= CURATED[1].id then
		return false, "the curated rows did not lead the list"
	end
	local tail = assembled[#assembled]
	if tail.name ~= "mistral-large" or tail.context ~= nil then
		return false, "a fetched row was given a name or a context window it has not got"
	end
	Nvidia.MODELS = restore

	if Nvidia.contextWindow("nvidia/nemotron-3-super-120b-a12b") ~= 262144 then
		return false, "a curated context window was not reported"
	end
	if Nvidia.contextWindow("someone/unlisted-model") ~= nil then
		return false, "a context window was invented for an unlisted model"
	end
	if not capsFor(Nvidia.DEFAULT_MODEL) then
		return false, "DEFAULT_MODEL is not one of the curated rows"
	end
	if not acceptsModelId("moonshotai/kimi-k3") or acceptsModelId("claude-sonnet-5") then
		return false, "acceptsModelId does not recognise a slug"
	end

	return true
end

-- The input window for a model id, for the settings panel's context row.
--
-- nil, not a guess, for anything not curated: GET /v1/models publishes no
-- context length, so every fetched row genuinely has no number behind it and a
-- made-up denominator turns a progress bar into a confident wrong reading. The
-- caller draws nothing instead.
function Nvidia.contextWindow(model: string): number?
	local caps = capsFor(model)
	local context = caps and caps.context
	return if type(context) == "number" and context > 0 then context else nil
end

Nvidia.Initialize = Initialize
Nvidia.streamMessage = streamMessage
Nvidia.acceptsModelId = acceptsModelId
Nvidia.refreshModels = refreshModels
Nvidia.selfTest = selfTest

return Nvidia
