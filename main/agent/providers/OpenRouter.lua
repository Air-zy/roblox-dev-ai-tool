--!optimize 2
-- OpenRouter.luau: OpenRouter over ChatCompletions, for its free models.
--
-- The model list is fetched rather than hardcoded, because which models are free
-- changes weekly, and filtered to those that can call tools. Effort goes out as
-- `reasoning: {effort}`, web search as `plugins: [{id="web"}]`, and reasoning is
-- replayed verbatim through the thinking block's signature.
--
-- Reference: https://openrouter.ai/docs/api-reference/overview

local HttpService = game:GetService("HttpService")

local ChatCompletions = require(script.Parent:WaitForChild("ChatCompletions"))
local ToolJson = require(script.Parent:WaitForChild("ToolJson"))

local OpenRouter = {}

-- Forward-declared: Initialize schedules it, and it is defined further down.
local refreshModels: () -> (boolean, string?)

local Auth: any = nil     -- set via Initialize
local plugin: any = nil   -- set via Initialize, for the model-list cache

local COMPLETIONS_URL = "https://openrouter.ai/api/v1/chat/completions"
local MODELS_URL = "https://openrouter.ai/api/v1/models"

-- Attribution. HTTP-Referer is left off: Roblox reserves some request headers,
-- and a rejected one fails the whole call.
local APP_TITLE = "Roblox Code Agent"

local KEY_MODEL_CACHE = "openrouter_models"
local KEY_MODEL_CACHE_AT = "openrouter_models_at"
-- The roster turns over in weeks and the endpoint is ~700KB: a day's cache is fine.
local MODEL_CACHE_MAX_AGE = 24 * 3600

-- Fallback for a first run, offline, or a failed fetch; it goes stale.
-- `openrouter/free` is a router to whatever is free now, so it cannot.
OpenRouter.MODELS = {
	{ id = "openrouter/free", label = "Free Models Router (auto)", name = "Free Router", hint = "free · auto" },
	{ id = "z-ai/glm-5.2:free", label = "Z.ai: GLM 5.2 (free)", name = "GLM 5.2", hint = "free · 256k" },
	{ id = "nvidia/nemotron-3-super-120b-a12b:free", label = "NVIDIA: Nemotron 3 Super (free)", name = "Nemotron 3 Super", hint = "free · 262k" },
	{ id = "google/gemma-4-31b-it:free", label = "Google: Gemma 4 31B (free)", name = "Gemma 4 31B", hint = "free · 262k" },
	{ id = "cohere/north-mini-code:free", label = "Cohere: North Mini Code (free)", name = "North Mini Code", hint = "free · 256k" },
}
OpenRouter.DEFAULT_MODEL = "openrouter/free"

-- Only these take explicit cache breakpoints. The rest cache automatically or
-- not at all, and an unknown field is not worth the risk.
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

	-- Cached list now, refresh in the background if stale.
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
-- "Z.ai: GLM 5.2 (free)" -> "GLM 5.2", for the chip on the input row.
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
	return type(params) == "table" and table.find(params, "tools") ~= nil
end

-- The live catalogue's free, tool-capable models. Every capability here is a
-- tool call, so a model without them can only narrate. Yields.
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
		-- Never replace a working list with an empty one.
		return false, "model list: nothing free with tool support"
	end
	-- Biggest context first: it decides how long a session can run.
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

-- Any `vendor/model` slug. The picker shows the free ones; `/model` takes the rest.
local function acceptsModelId(id: string): boolean
	return id:find("/", 1, true) ~= nil
end

-- Outbound
local function cached(text: string): { any }
	return { { type = "text", text = text, cache_control = { type = "ephemeral", ttl = "1h" } } }
end

-- ChatCompletions' flattening with reasoning replayed, plus cache breakpoints on
-- the system prompt and the last message for the models that take them. Never
-- on a `tool` message, whose content must stay a bare string.
local function toChatMessages(system: string?, messages: { any }, model: string): { any }
	local out = ChatCompletions.toMessages(system, messages, true)
	if not wantsExplicitCache(model) then return out end
	local first, last = out[1], out[#out]
	if first and first.role == "system" then first.content = cached(first.content) end
	if last and last.role ~= "tool" and type(last.content) == "string" then
		last.content = cached(last.content)
	end
	return out
end

local function streamMessage(args: any, callbacks: any): any
	return ChatCompletions.stream({
		name = "OpenRouter",
		auth = Auth,
		url = COMPLETIONS_URL,
		headers = { ["X-Title"] = APP_TITLE },
		reasoningField = "reasoning",
		body = function()
			local model = args.model or OpenRouter.DEFAULT_MODEL
			local body: { [string]: any } = {
				model = model,
				stream = true,
				messages = toChatMessages(args.system, args.messages, model),
			}
			-- No max_tokens: it defaults to each model's own ceiling.
			if args.effort and args.effort ~= "" then
				body.reasoning = { effort = args.effort }
			end
			-- OpenRouter runs the search itself and splices the results in.
			if args.webSearch and args.webSearch > 0 then
				body.plugins = { { id = "web", max_results = args.webSearch } }
			end
			return body
		end,

		-- A 402 on a free model names none of its causes: the daily cap shared by
		-- every free model, a key capped at $0, or a negative balance.
		explain = function(status: number?, _body: string?): string?
			if status ~= 402 then return nil end
			return string.format(
				"Out of free requests, or this key cannot spend. The free cap is shared "
				.. "across ALL free models (%d/day, %d once $10 of credits has ever been "
				.. "bought) and resets at UTC midnight, so switching models will not help. "
				.. "Settings shows this key's own limit; a key created with a $0 cap is "
				.. "refused for free models too.", Auth.FREE_RPD, Auth.PAID_RPD)
		end,
	}, args, callbacks)
end

-- Self-test
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

	-- `{}` encodes as `[]`, and `arguments: []` is rejected.
	if ToolJson.encode({}) ~= "{}" then
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

	-- Cache breakpoints only for the models that take them.
	local anthropic = toChatMessages("sys", { { role = "user", content = "hi" } }, "anthropic/claude-sonnet-5")
	if type(anthropic[1].content) ~= "table" or not anthropic[1].content[1].cache_control then
		return false, "no cache breakpoint on a provider that needs one"
	end
	local free = toChatMessages("sys", { { role = "user", content = "hi" } }, "z-ai/glm-5.2:free")
	if type(free[1].content) ~= "string" then
		return false, "a cache breakpoint was sent to a model that does not take one"
	end

	-- input_schema becomes parameters; the Anthropic-only flag is dropped.
	local wireTools = ChatCompletions.toTools({
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

	-- Model filtering: free AND tool-capable.
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

-- The input window for the settings panel's context row, off the fetched roster.
-- nil rather than a guess for the fallback rows, which have none.
function OpenRouter.contextWindow(model: string): number?
	for _, entry in ipairs(OpenRouter.MODELS) do
		if entry.id == model then
			local context = (entry :: any).context
			return if type(context) == "number" and context > 0 then context else nil
		end
	end
	return nil
end

OpenRouter.Initialize = Initialize
OpenRouter.streamMessage = streamMessage
OpenRouter.acceptsModelId = acceptsModelId
OpenRouter.refreshModels = refreshModels
OpenRouter.selfTest = selfTest

return OpenRouter
