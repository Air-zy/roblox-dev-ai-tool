--!optimize 2
-- Nvidia.luau: NVIDIA NIM over ChatCompletions. A second free tier, metered per
-- minute for the whole KEY rather than per day. No response carries a rate-limit
-- header, so NvidiaAuth counts our own sends.
--
-- Where this endpoint differs, each of which breaks the harness if missed:
--   * max_tokens defaults to 2048, so it is always sent.
--   * Two reasoning switches, `reasoning_effort` and `chat_template_kwargs`;
--     which one a model takes lives on its CURATED row.
--   * Nemotron needs `force_nonempty_content`, or tool calls come back as prose.
--   * Usage is only reported with `stream_options.include_usage`.
--   * Reasoning streams as `reasoning_content` and is never sent back: there is
--     no field for it.
--   * No prompt caching, no server-side search, no keepalive comments.
--
-- Reference: https://docs.api.nvidia.com/nim/reference/llm-apis

local HttpService = game:GetService("HttpService")

local ChatCompletions = require(script.Parent:WaitForChild("ChatCompletions"))
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

-- ponytail: one number for every id CURATED has never heard of. A model with a
-- lower output cap answers 400; the upgrade path is a maxOutput on its row.
local DEFAULT_MAX_TOKENS = 16384

-- NVIDIA has no `xhigh`, and an unknown value fails the request.
local EFFORT_MAP: { [string]: string } = { xhigh = "high" }

-- Hand-written: GET /v1/models returns ids and nothing else. Figures are off each
-- model's build.nvidia.com page, and `context` is omitted where none is published.
-- Left out: minimaxai/minimax-m3 and z-ai/glm-5.2, whose tool-call arguments stall
-- for minutes with no [DONE] (an InactivityTimeout here). /model still reaches them.
local CURATED: { any } = {
	{
		id = "nvidia/nemotron-3-super-120b-a12b",
		label = "NVIDIA: Nemotron 3 Super",
		name = "Nemotron 3 Super",
		hint = "256k · reasoning",
		-- "Up to 1M" with a 256k default; the hosted one is unpublished, so the
		-- smaller, which errs toward clearing early.
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
		-- Strong, but its tool calls do not always arrive as delta.tool_calls here.
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

-- nil for an id typed in by hand, which keeps reasoning fields off unknown models.
local function capsFor(model: string): any?
	for _, entry in ipairs(CURATED) do
		if entry.id == model then return entry end
	end
	return nil
end

-- Model list
-- "mistralai/mistral-large" -> "mistral-large", for the chip on the input row.
local function shortName(id: string): string
	return id:match("^[^/]+/(.+)$") or id
end

-- Curated first, then everything else the endpoint lists.
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
			-- No context or hint: nothing is published for these.
			out[#out + 1] = { id = id, label = id, name = shortName(id) }
		end
	end
	Nvidia.MODELS = out
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
				applyTail(decoded)
			end
		end
		local at = plugin:GetSetting(KEY_MODEL_CACHE_AT)
		if type(at) ~= "number" or os.time() - at > MODEL_CACHE_MAX_AGE then
			task.spawn(refreshModels)
		end
	end
end

-- The catalogue's ids, unfiltered: nothing in it says which can call tools. No
-- Authorization, since the endpoint is public and the picker fills before login.
-- Caches ids only, so curated rows always come from this build. Yields.
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

-- Any `vendor/model` slug; some reachable models are missing from the catalogue.
local function acceptsModelId(id: string): boolean
	return id:find("/", 1, true) ~= nil
end

-- Outbound
local function maxTokensFor(model: string): number
	local caps = capsFor(model)
	return (caps and caps.maxOutput) or DEFAULT_MAX_TOKENS
end

-- The reasoning switch this model takes, if any. An uncurated id gets neither:
-- an unrecognised parameter fails the whole request.
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
			-- Required for tool use, or calls come back as prose with finish "stop".
			force_nonempty_content = true,
		}
		-- The only level with its own switch; the rest all mean "think normally".
		if effort == "low" then kwargs.low_effort = true end
		body.chat_template_kwargs = kwargs
	end
end

local function streamMessage(args: any, callbacks: any): any
	return ChatCompletions.stream({
		name = "NVIDIA",
		auth = Auth,
		url = COMPLETIONS_URL,
		reasoningField = "reasoning_content",
		body = function()
			local model = args.model or Nvidia.DEFAULT_MODEL
			local body: { [string]: any } = {
				model = model,
				stream = true,
				messages = ChatCompletions.toMessages(args.system, args.messages),
				max_tokens = args.maxTokens or maxTokensFor(model),
				stream_options = { include_usage = true },
			}
			applyReasoning(body, model, args.effort)
			return body
		end,

		-- NVIDIA's own bodies say "Authorization failed" and nothing about why.
		explain = function(status: number?, body: string?): string?
			if status == 401 or status == 403 then
				return "NVIDIA rejected the key. Personal keys EXPIRE — six months, unless the "
					.. "key was created as \"Never Expire\" — so one that worked last month can "
					.. "stop with no warning. Generate another at "
					.. tostring(Auth and Auth.API_KEYS_URL) .. " and paste it with /code."
			end
			-- "Overloaded" is the shared fleet, in-band inside a 200; a rate limit is a 429.
			if body and string.find(string.lower(body), "overload", 1, true) then
				return "NVIDIA's capacity, not your rate limit — the fleet is busy and this is "
					.. "retried automatically with backoff. A rate limit would say 429 / Too Many "
					.. "Requests instead. If it keeps happening, status.build.nvidia.com has the "
					.. "fleet status and another model often has capacity when one does not."
			end
			if status == 429 then
				local sent = (Auth and Auth.recentRequests and Auth.recentRequests()) or 0
				return string.format(
					"Rate limited after %d requests in the last minute. The limit is one budget "
					.. "for the whole KEY, shared across every model, so switching model will not "
					.. "help — only waiting will. NVIDIA does not publish the number or send a "
					.. "rate-limit header; ~%d/min is the usual free-tier figure and the real one "
					.. "for this account is on build.nvidia.com, which is also where an increase "
					.. "is requested. An agent turn is many requests rather than one, so this "
					.. "arrives sooner here than it would in a chat window.",
					sent, (Auth and Auth.FREE_RPM) or 40)
			end
			return nil
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
	local out = ChatCompletions.toMessages("be brief", conversation)

	if HttpService:JSONEncode(conversation) ~= before then
		return false, "toMessages mutated the caller's conversation"
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
	-- No field to replay reasoning into, and inventing one fails the request.
	if (out[3] :: any).reasoning ~= nil or (out[3] :: any).reasoning_content ~= nil then
		return false, "reasoning was sent back to an endpoint that does not take it"
	end
	-- The batch-to-one-message-each fan-out, and the id that pairs them.
	if out[4].role ~= "tool" or out[4].tool_call_id ~= "call_1" or out[4].content ~= "Baseplate" then
		return false, "a tool_result did not become a tool message"
	end

	-- `{}` encodes as `[]`, and `arguments: []` is rejected.
	if ToolJson.encode({}) ~= "{}" then
		return false, "an empty tool input did not encode as an object"
	end

	-- max_tokens: absent or 2048 truncates every turn.
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

	-- No cache breakdown here, so prompt_tokens passes through untouched.
	local u = ChatCompletions.rebaseUsage({ prompt_tokens = 120, completion_tokens = 30, total_tokens = 150 })
	if not u or u.input_tokens ~= 120 or u.output_tokens ~= 30 then
		return false, "NIM-shaped usage did not rebase"
	end
	if u.cache_read_input_tokens ~= 0 or u.cache_creation_input_tokens ~= 0 then
		return false, "cache fields were invented for an endpoint that does not cache"
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
		return false, "an Anthropic-only tool flag was sent to NVIDIA"
	end

	-- Curated first, fetched tail after, no duplicates, no context on the tail.
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

-- The input window for the settings panel's context row; nil for anything not
-- curated, since nothing publishes one.
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
