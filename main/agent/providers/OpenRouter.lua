--!optimize 2
-- OpenRouter.luau: chat/completions client, one request, SSE back.
--
-- The point of this provider is the free tier: OpenRouter fronts a rotating set
-- of models that cost nothing, which is the only way to run this plugin without
-- a Claude subscription. Everything here is bent toward that — the model list
-- is FETCHED rather than hardcoded because which models are free changes week to
-- week, and it is filtered to the ones that can call tools, because a model that
-- cannot is useless to a harness that is nothing but tools.
--
-- TRANSLATION, and it is the whole file.
--
-- The conversation this plugin keeps is Anthropic-shaped: content is a list of
-- typed blocks, thinking carries a signature, a tool call lives inline in the
-- assistant's content, and a batch of tool results arrives as ONE user message.
-- Agent, Sessions and Find all read that shape. Rather than teach four modules a
-- second one, this file converts at its own edge, in both directions. The
-- direction is what makes it work: the Anthropic shape is strictly the richer
-- of the two, so going out is a lossless flattening and coming back is a
-- mechanical rebuild.
--
--   Anthropic-shaped (internal)          OpenAI-shaped (the wire)
--   -------------------------------------------------------------------
--   system: [blocks]                     messages[0] = {role="system"}
--   user content: "string"               same
--   user content: [tool_result, ...]     N x {role="tool", tool_call_id}
--   assistant text block                 content: "string"
--   assistant thinking + signature       reasoning_details[] (see below)
--   assistant tool_use block             tool_calls[{id, function{name,arguments}}]
--   tools[{name, input_schema}]          tools[{type="function", function{parameters}}]
--   output_config.effort                 reasoning: {effort}
--   web search as a server tool          plugins: [{id="web"}]
--
-- The signature is the interesting one. Provider.luau already says a thinking
-- block's signature is an opaque blob only its own provider can read, so this
-- uses it as exactly that: a JSON envelope holding OpenRouter's
-- `reasoning_details` (or plain reasoning text when a model sends no details).
-- Agent and Sessions carry it around without looking inside, which is the
-- contract they were already written to.
--
-- Reference: https://openrouter.ai/docs/api-reference/overview

local HttpService = game:GetService("HttpService")
local warn = warn

local Stream = require(script.Parent:WaitForChild("Stream"))
local ToolJson = require(script.Parent:WaitForChild("ToolJson"))

local OpenRouter = {}

-- Forward-declared: Initialize schedules it, and it is defined further down.
local refreshModels: () -> (boolean, string?)

local Auth: any = nil     -- set via Initialize
local plugin: any = nil   -- set via Initialize, for the model-list cache

local COMPLETIONS_URL = "https://openrouter.ai/api/v1/chat/completions"
local MODELS_URL = "https://openrouter.ai/api/v1/models"

-- Attribution, and the only optional header sent. OpenRouter also documents
-- HTTP-Referer for its rankings; it is left off because Roblox reserves a
-- handful of request headers and a rejected one fails the whole call, which is
-- a poor trade for a leaderboard entry.
local APP_TITLE = "Claude Code for Roblox"

local KEY_MODEL_CACHE = "openrouter_models"
local KEY_MODEL_CACHE_AT = "openrouter_models_at"
-- The free roster turns over on the order of weeks, so a day-old list is fine
-- and a fetch on every Studio launch is not: the models endpoint is ~700KB.
local MODEL_CACHE_MAX_AGE = 24 * 3600

-- Fallback only, and it WILL go stale — that is why the fetch below exists.
-- Kept so the picker has something on a first run, offline, or when the fetch
-- fails. `openrouter/free` leads because it is a router rather than a model:
-- it dispatches to whatever is free right now, so it is the one id here that
-- cannot rot.
OpenRouter.MODELS = {
	{ id = "openrouter/free", label = "Free Models Router (auto)", name = "Free Router", hint = "free · auto" },
	{ id = "z-ai/glm-5.2:free", label = "Z.ai: GLM 5.2 (free)", name = "GLM 5.2", hint = "free · 256k" },
	{ id = "nvidia/nemotron-3-super-120b-a12b:free", label = "NVIDIA: Nemotron 3 Super (free)", name = "Nemotron 3 Super", hint = "free · 262k" },
	{ id = "google/gemma-4-31b-it:free", label = "Google: Gemma 4 31B (free)", name = "Gemma 4 31B", hint = "free · 262k" },
	{ id = "cohere/north-mini-code:free", label = "Cohere: North Mini Code (free)", name = "North Mini Code", hint = "free · 256k" },
}
OpenRouter.DEFAULT_MODEL = "openrouter/free"

-- Explicit cache breakpoints are an Anthropic and Qwen thing. Everyone else
-- either caches automatically (OpenAI, Gemini 2.5, DeepSeek, Groq…) or not at
-- all, and sending a field a provider does not know is not worth the risk for
-- models that are free anyway.
local EXPLICIT_CACHE_PREFIXES = { "anthropic/", "qwen/" }

local function wantsExplicitCache(model: string): boolean
	for _, prefix in ipairs(EXPLICIT_CACHE_PREFIXES) do
		if model:sub(1, #prefix) == prefix then return true end
	end
	return false
end

local function Initialize(authModule: any, pluginRef: any)
	Auth = authModule
	plugin = pluginRef

	-- Warm the model list from the cache immediately, then refresh in the
	-- background if it is stale. Nothing waits on the network to draw a picker.
	if plugin then
		local cached = plugin:GetSetting(KEY_MODEL_CACHE)
		if type(cached) == "string" and cached ~= "" then
			local ok, decoded = pcall(function() return HttpService:JSONDecode(cached) end)
			if ok and type(decoded) == "table" and #decoded > 0 then
				OpenRouter.MODELS = decoded
			end
		end
		local at = plugin:GetSetting(KEY_MODEL_CACHE_AT)
		if type(at) ~= "number" or os.time() - at > MODEL_CACHE_MAX_AGE then
			task.spawn(refreshModels)
		end
	end
end

-- Model list
-- "Z.ai: GLM 5.2 (free)" -> "GLM 5.2". The vendor is already obvious from the
-- id and the chip at the corner of the input row has room for about that much.
local function shortName(name: string): string
	local trimmed = name:gsub("%s*%(free%)%s*$", "")
	local after = trimmed:match(":%s*(.+)$")
	return after or trimmed
end

local function contextHint(contextLength: any): string
	if type(contextLength) ~= "number" or contextLength <= 0 then return "" end
	if contextLength >= 1000000 then
		return string.format("%gM", contextLength / 1000000)
	end
	return string.format("%dk", math.floor(contextLength / 1000))
end

local function isFree(pricing: any): boolean
	if type(pricing) ~= "table" then return false end
	return (tonumber(pricing.prompt) or 1) == 0 and (tonumber(pricing.completion) or 1) == 0
end

local function supportsTools(entry: any): boolean
	local params = entry.supported_parameters
	if type(params) ~= "table" then return false end
	for _, name in ipairs(params) do
		if name == "tools" then return true end
	end
	return false
end

-- Fetches the live catalogue and keeps the free, tool-capable half of it.
--
-- Both filters are load-bearing. Free is the entire reason this provider
-- exists. Tool support is a hard requirement rather than a preference: every
-- capability this plugin has is a tool call, so a model without them can only
-- ever narrate what it would have done. Roughly a fifth of the free roster
-- fails that test at any given time.
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

	local out: { any } = {}
	for _, entry in ipairs(data) do
		if isFree(entry.pricing) and supportsTools(entry) then
			local hint = contextHint(entry.context_length)
			out[#out + 1] = {
				id = entry.id,
				label = entry.name or entry.id,
				name = shortName(entry.name or entry.id),
				hint = if hint ~= "" then "free · " .. hint else "free",
				context = entry.context_length or 0,
			}
		end
	end
	if #out == 0 then
		-- Never replace a working list with an empty one: a filter that matched
		-- nothing leaves the picker unusable, and the fallback above is better
		-- than that even when it is out of date.
		return false, "model list: nothing free with tool support"
	end
	-- Biggest context first. For an agent that resends the whole conversation
	-- every turn, that is the axis that decides how long a session can run.
	table.sort(out, function(a, b) return a.context > b.context end)

	OpenRouter.MODELS = out
	if plugin then
		pcall(function()
			plugin:SetSetting(KEY_MODEL_CACHE, HttpService:JSONEncode(out))
			plugin:SetSetting(KEY_MODEL_CACHE_AT, os.time())
		end)
	end
	return true
end

-- Any `vendor/model` slug is a real model id here, and there are several
-- hundred of them — far too many to put in a popup, so the picker shows the
-- free ones and this lets `/model anything/else` through untouched.
local function acceptsModelId(id: string): boolean
	return id:find("/", 1, true) ~= nil
end

-- Outbound
local function toolArguments(input: any): string
	-- An empty Lua table encodes as `[]`, and `arguments` must be a JSON OBJECT.
	-- Agent already guards its own side of this; the encode here is a second
	-- place it can happen and costs one comparison to get right.
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

-- Reads back what the parser stashed in a thinking block's signature. Returns
-- the reasoning_details array if the model sent one, else plain text.
local function reasoningFrom(signature: string?): (any?, string?)
	if type(signature) ~= "string" or signature == "" then return nil, nil end
	local ok, env = pcall(function() return HttpService:JSONDecode(signature) end)
	if not ok or type(env) ~= "table" then return nil, nil end
	return (env :: any).d, (env :: any).t
end

-- The whole conversation, flattened. Returns a NEW array: `messages` is the
-- live table Agent appends to and Sessions persists, and writing request
-- shaping into it would leak onto the screen and into storage. Anthropic.luau's
-- withMessageCache carries the scars from when that was learned.
local function toChatMessages(system: string?, messages: { any }, model: string): { any }
	local out: { any } = {}
	local explicitCache = wantsExplicitCache(model)

	if system and system ~= "" then
		if explicitCache then
			out[#out + 1] = {
				role = "system",
				content = { { type = "text", text = system, cache_control = { type = "ephemeral", ttl = "1h" } } },
			}
		else
			out[#out + 1] = { role = "system", content = system }
		end
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
			local details: any = nil
			local reasoningText: string? = nil

			for _, block in ipairs(content) do
				if block.type == "text" and block.text then
					texts[#texts + 1] = block.text
				elseif block.type == "tool_use" then
					toolCalls[#toolCalls + 1] = {
						id = block.id,
						type = "function",
						["function"] = { name = block.name, arguments = toolArguments(block.input) },
					}
				elseif block.type == "thinking" then
					local d, t = reasoningFrom(block.signature)
					if d then details = d elseif t then reasoningText = t end
				end
				-- server_tool_use and its result blocks are Anthropic-executed and
				-- cannot appear in a conversation this provider created. A session
				-- is bound to the provider that made it, so reaching one here means
				-- something upstream let a cross-provider restore through.
			end

			local assistant: { [string]: any } = { role = "assistant" }
			assistant.content = if #texts > 0 then table.concat(texts, "\n") else ""
			if #toolCalls > 0 then assistant.tool_calls = toolCalls end
			-- Passed back unmodified, which is the documented requirement: the
			-- sequence of reasoning blocks has to match what the model generated
			-- or the request is rejected.
			if details then
				assistant.reasoning_details = details
			elseif reasoningText then
				assistant.reasoning = reasoningText
			end
			out[#out + 1] = assistant
		end
	end

	-- The moving breakpoint on the conversation. Same argument as Anthropic: the
	-- history before it becomes a cache read rather than a reprocess on the next
	-- turn. Only on the last message, and never on a `tool` message, whose
	-- content must stay a bare string.
	if explicitCache and #out > 0 then
		local last = out[#out]
		if last.role ~= "tool" and type(last.content) == "string" then
			last.content = {
				{ type = "text", text = last.content, cache_control = { type = "ephemeral", ttl = "1h" } },
			}
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
					-- Anthropic tool-definition flag. Argument fragments stream by
					-- default in this format, which is what it existed to force.
					parameters = tool.input_schema,
				},
			}
		end
	end
	return if #out > 0 then out else nil
end

-- streamMessage
-- Same signature and the same callbacks as Anthropic.streamMessage, because
-- Agent drives both through one code path.
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
		if callbacks.onError then callbacks.onError("OpenRouter module not initialized.") end
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

	local model = args.model or OpenRouter.DEFAULT_MODEL

	local bodyTable: { [string]: any } = {
		model = model,
		stream = true,
		messages = toChatMessages(args.system, args.messages, model),
	}

	-- max_tokens is deliberately NOT sent. It is optional, it defaults to the
	-- model's own ceiling, and the alternative is a hand-maintained per-model
	-- table across several hundred models that turn over weekly. Anthropic.luau
	-- keeps one for three models and the comment there already calls it stale.
	if args.effort and args.effort ~= "" then
		bodyTable.reasoning = { effort = args.effort }
	end

	local tools = toChatTools(args.tools)
	if tools then
		bodyTable.tools = tools
		bodyTable.tool_choice = "auto"
	end

	-- A body field rather than a tool in the array: OpenRouter runs the search
	-- itself and splices the results in. Anthropic's equivalent is a server tool
	-- appended to `tools`, which is exactly why Agent passes a COUNT and lets
	-- each provider decide what a search is.
	if args.webSearch and args.webSearch > 0 then
		bodyTable.plugins = { { id = "web", max_results = args.webSearch } }
	end

	local bodyStr = HttpService:JSONEncode(bodyTable)

	-- Accumulators, rebuilt per attempt by `reset` below.
	local textAcc = ""
	local reasonAcc = ""
	local reasoningDetails: { any } = {}
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
		if reasonAcc ~= "" or #reasoningDetails > 0 then
			-- The signature is this provider's opaque blob, and it holds whatever
			-- has to go back on the next turn: the details array when the model
			-- sent one, the plain text when it did not. Agent drops a thinking
			-- block that has no signature, so there is always one.
			blocks[#blocks + 1] = {
				type = "thinking",
				thinking = reasonAcc,
				signature = HttpService:JSONEncode({
					d = if #reasoningDetails > 0 then reasoningDetails else nil,
					t = if reasonAcc ~= "" then reasonAcc else nil,
				}),
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

	local function readUsage(u: any)
		if type(u) ~= "table" then return end
		-- Rebased, and this is the subtle one. Anthropic reports input_tokens
		-- EXCLUDING what it read from cache; OpenAI-shaped usage reports
		-- prompt_tokens INCLUDING it. Agent adds input + cache_read +
		-- cache_creation to get the turn's true input, so handing it
		-- prompt_tokens raw double-counts every cached token — silently, in the
		-- direction that flatters the cache hit rate.
		local details = u.prompt_tokens_details
		local cached = (type(details) == "table" and details.cached_tokens) or u.cached_tokens or 0
		local written = u.cache_write_tokens or 0
		local prompt = u.prompt_tokens or 0
		usage = {
			input_tokens = math.max(prompt - cached - written, 0),
			cache_read_input_tokens = cached,
			cache_creation_input_tokens = written,
			output_tokens = u.completion_tokens or 0,
		}
	end

	local function readToolCalls(calls: any, ctrl: Stream.Ctrl)
		for _, call in ipairs(calls) do
			-- `index` identifies the call across chunks; id and name arrive on the
			-- first fragment for it and the arguments dribble in after.
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
			-- on screen while the arguments are still being written. For a `write`
			-- whose argument IS the file, that is the difference between a header
			-- appearing now and appearing a minute from now.
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
			-- ": OPENROUTER PROCESSING" and friends. Comments per the SSE spec,
			-- and on this host they are worth more than they look: Roblox closes a
			-- stream that goes quiet, so a keepalive is what keeps a slow model
			-- from being killed as an InactivityTimeout before its first token.
			if line:sub(1, 1) ~= ":" then
				local data = line:match("^data:%s*(.+)$")
				if data == "[DONE]" then
					complete(ctrl)
					return
				elseif data then
					local parsed
					if not pcall(function() parsed = HttpService:JSONDecode(data) end) then
						-- Unreadable frame. Was worth a `continue` when this ran
						-- inside a buffer loop; one frame is one call now.
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

					if chunk.usage then readUsage(chunk.usage) end

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
							if type(delta.reasoning) == "string" and delta.reasoning ~= "" then
								ctrl.emitted()
								reasonAcc ..= delta.reasoning
								if callbacks.onThinking then callbacks.onThinking(delta.reasoning) end
							end
							-- Kept verbatim and in order. These are what go back on
							-- the next turn, and the sequence may not be rearranged.
							if type(delta.reasoning_details) == "table" then
								for _, detail in ipairs(delta.reasoning_details) do
									reasoningDetails[#reasoningDetails + 1] = detail
								end
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
					["X-Title"] = APP_TITLE,
				},
				body = bodyStr,
			}
		end,

		reset = function()
			textAcc = ""
			reasonAcc = ""
			reasoningDetails = {}
			toolAcc = {}
			toolCount = 0
			usage = nil
			stopReason = nil
			completed = false
		end,

		frame = onFrame,

		-- A clean close with no [DONE]. Rare, but a stream that ends politely
		-- fires no error, so without this the turn would sit spinning until
		-- somebody pressed Stop. Anything already accumulated is delivered.
		closed = function(ctrl: Stream.Ctrl)
			if stopReason or textAcc ~= "" or toolCount > 0 then
				complete(ctrl)
			end
		end,

		partial = function(): string?
			return if textAcc ~= "" then textAcc else nil
		end,

		-- A 402 on a model that costs nothing is confusing enough to be worth
		-- spelling out, because the raw message names none of its three causes.
		-- The free daily request cap is SHARED across every free model, so
		-- switching models cannot help and it looks like they are all broken; a
		-- key can carry a spending limit of its own, and one capped at $0 refuses
		-- free models too; and a negative account balance blocks them as well.
		-- Worth saying here rather than anywhere else: an agent turn is many
		-- requests, not one, so a 50/day cap goes faster in this plugin than it
		-- would in a chat window.
		explain = function(status: number?, _body: string?): string?
			if status ~= 402 then return nil end
			return string.format(
				"Out of free requests, or this key cannot spend. The free cap is shared "
				.. "across ALL free models (%d/day, %d once $10 of credits has ever been "
				.. "bought) and resets at UTC midnight, so switching models will not help. "
				.. "Settings shows this key's own limit; a key created with a $0 cap is "
				.. "refused for free models too.", Auth.FREE_RPD, Auth.PAID_RPD)
		end,

		-- No refresh hook: an OpenRouter key does not expire, so a 401 means it
		-- was deleted and asking again with the same one cannot help.
	}, {
		onError = callbacks.onError,
		onRetry = callbacks.onRetry,
	})
end

-- Self-test
-- Translation is the whole file, and every way it can be wrong is quiet: a
-- dropped tool_call_id desyncs the next turn, a mutated conversation corrupts
-- the saved session, and usage rebased wrongly just prints a flattering number.
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
	local out = toChatMessages("be brief", conversation, "z-ai/glm-5.2:free")

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
	if out[3].reasoning ~= "a summary" then
		return false, "plain reasoning text was not replayed"
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

	-- reasoning_details round-trip through the signature envelope.
	local details = { { type = "reasoning.encrypted", data = "xyz" } }
	local envelope = HttpService:JSONEncode({ d = details })
	local back = toChatMessages(nil, {
		{ role = "assistant", content = {
			{ type = "thinking", thinking = "", signature = envelope },
		} },
	}, "openrouter/free")
	if not back[1].reasoning_details or back[1].reasoning_details[1].data ~= "xyz" then
		return false, "reasoning_details did not survive the signature envelope"
	end

	-- Explicit cache breakpoints are for the providers that need them, and must
	-- not be sent to the free models this exists to serve.
	local anthropic = toChatMessages("sys", { { role = "user", content = "hi" } }, "anthropic/claude-sonnet-5")
	if type(anthropic[1].content) ~= "table" or not anthropic[1].content[1].cache_control then
		return false, "no cache breakpoint on a provider that needs one"
	end
	local free = toChatMessages("sys", { { role = "user", content = "hi" } }, "z-ai/glm-5.2:free")
	if type(free[1].content) ~= "string" then
		return false, "a cache breakpoint was sent to a model that does not take one"
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
		return false, "an Anthropic-only tool flag was sent to OpenRouter"
	end

	-- Model filtering. Free with tools stays; free without tools goes, which is
	-- the filter that decides whether the picker offers something unusable.
	if not isFree({ prompt = "0", completion = "0" }) then
		return false, "a free model was not recognised as free"
	end
	if isFree({ prompt = "0.0000001", completion = "0" }) then
		return false, "a paid model was counted as free"
	end
	if supportsTools({ supported_parameters = { "reasoning", "max_tokens" } }) then
		return false, "a model without tool support passed the filter"
	end
	if not supportsTools({ supported_parameters = { "tools", "tool_choice" } }) then
		return false, "a tool-capable model was filtered out"
	end
	if shortName("Z.ai: GLM 5.2 (free)") ~= "GLM 5.2" then
		return false, "shortName: got " .. shortName("Z.ai: GLM 5.2 (free)")
	end
	if not acceptsModelId("qwen/qwen3-coder:free") or acceptsModelId("claude-sonnet-5") then
		return false, "acceptsModelId does not recognise a slug"
	end

	return true
end

OpenRouter.Initialize = Initialize
OpenRouter.streamMessage = streamMessage
OpenRouter.acceptsModelId = acceptsModelId
OpenRouter.refreshModels = refreshModels
OpenRouter.selfTest = selfTest

return OpenRouter
