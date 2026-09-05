--!optimize 2
-- Gemini.luau: Google's native generateContent API, one request, SSE back.
--
-- The NATIVE wire, not Google's OpenAI-compatibility layer, and the choice is
-- load-bearing rather than a preference. Three things only exist here:
--
--   * THOUGHT SIGNATURES. Gemini 3 rejects a tool-calling turn whose replayed
--     history is missing them — "the first functionCall part in each step of the
--     current turn MUST include its thought_signature", 400 otherwise, and
--     `MISSING_THOUGHT_SIGNATURE` is a finishReason the API can hand back. On
--     the compatibility layer they are a bolt-on inside an `extra_content`
--     wrapper; here they are a field on the part that owns them.
--   * GET /v1beta/models returns `inputTokenLimit`, `outputTokenLimit` and a
--     `thinking` boolean PER MODEL. That is every number the rest of this plugin
--     wants, so unlike the other three providers there is no hand-written caps
--     table here at all and the context bar is a real reading. The OpenAI list
--     endpoint degrades to {id, object, created} and would have needed one.
--   * `thoughtsTokenCount`. Thinking tokens are billed and are NOT part of
--     candidatesTokenCount; the compatibility layer does not report them, so
--     they would silently vanish from the usage panel.
--
-- Google's own documentation calls that layer beta and says unlisted parameters
-- are "silently ignored", which is the worst failure mode available to a harness.
--
-- TRANSLATION, and it is most of the file.
--
-- The conversation this plugin keeps is Anthropic-shaped. OpenRouter.luau's
-- header explains that shape and why each provider converts at its own edge;
-- this is the same job against a wire that is further away than OpenAI's.
--
--   Anthropic-shaped (internal)        Gemini (the wire)
--   ---------------------------------------------------------------------
--   system: string                     systemInstruction: {parts:[{text}]}
--   role "assistant"                   role "model"  (only user|model exist)
--   user content: "string"             {role:"user", parts:[{text}]}
--   user content: [tool_result, ...]   parts:[{functionResponse{id,name,response}}]
--   assistant text block               {text}
--   assistant thinking + signature     {text, thought:true, thoughtSignature}
--   assistant tool_use block           {functionCall{id,name,args}, thoughtSignature}
--   tools[{name, input_schema}]        tools[{functionDeclarations[…]}]
--   output_config.effort               generationConfig.thinkingConfig.thinkingLevel
--
-- Two of those rows are harder than they look.
--
-- `functionResponse` requires the function's NAME, and an internal tool_result
-- block carries only the id it answers. So the walk keeps an id -> name map as
-- it goes and resolves the name from the tool_use that came earlier in the same
-- conversation.
--
-- A signature belongs to the PART that produced it — usually a functionCall —
-- but Agent rebuilds a tool_use block as exactly {type, id, name, input} and
-- drops anything else on it. The one field that survives a turn untouched is a
-- thinking block's `signature`, which Provider.luau already defines as an opaque
-- blob only its own provider reads. So that is what carries them: one envelope
-- holding the thought text, the thought part's own signature, and a map of
-- call id -> signature, unpacked again on the way out. Same trick as
-- OpenRouter's `reasoning_details`, doing more work.
--
-- ON THE SURFACE THIS TALKS TO, because it is the older of two.
--
-- Google shipped an Interactions API in June 2026 and now calls generateContent
-- legacy. Legacy here means what it should: "remains fully supported", with no
-- removal date. It is not a deprecation, and nothing below is on borrowed time.
--
-- Worth knowing anyway, because the difference is not cosmetic. Interactions
-- keeps conversation state SERVER side behind a previous_interaction_id, where
-- this replays the whole history every turn — which is the thing Agent's context
-- accounting exists to manage. New agent-shaped features are also landing there
-- only. If this ever gets rewritten onto it, that is the reason, and the
-- translation below is the part that would be thrown away.
--
-- Reference: https://ai.google.dev/api/generate-content
--            https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures
--            https://ai.google.dev/gemini-api/docs/migrate-to-interactions

local HttpService = game:GetService("HttpService")
local warn = warn

local Stream = require(script.Parent:WaitForChild("Stream"))

local Gemini = {}

-- Forward-declared: Initialize schedules it, and it is defined further down.
local refreshModels: () -> (boolean, string?)

local Auth: any = nil     -- set via Initialize
local plugin: any = nil   -- set via Initialize, for the model-list cache

local API_BASE = "https://generativelanguage.googleapis.com/v1beta/"
-- pageSize is pushed to the ceiling so the roster arrives in one response;
-- paging through it would be three round trips to build one picker.
local MODELS_URL = API_BASE .. "models?pageSize=1000"

local KEY_MODEL_CACHE = "gemini_models"
local KEY_MODEL_CACHE_AT = "gemini_models_at"
local MODEL_CACHE_MAX_AGE = 24 * 3600

-- Five levels here, four in the enum, so the top three collapse. HIGH is the
-- ceiling the API offers and asking for more than the most it has is not an
-- error worth inventing.
local EFFORT_MAP: { [string]: string } = {
	low = "LOW",
	medium = "MEDIUM",
	high = "HIGH",
	xhigh = "HIGH",
	max = "HIGH",
}

-- A first-run stub, replaced wholesale by the fetch below. Deliberately carries
-- no `context`: the real number arrives with the roster, and a guessed
-- denominator turns the context bar into a confident wrong reading. `thinking`
-- IS set, because both of these are documented thinking models and defaulting it
-- off would mean no reasoning on the very first turn.
local SEED: { any } = {
	{ id = "gemini-3.8-flash", label = "Gemini 3.8 Flash", name = "3.8 Flash", thinking = true },
	{ id = "gemini-2.5-flash", label = "Gemini 2.5 Flash", name = "2.5 Flash", thinking = true },
}

Gemini.MODELS = SEED
-- Only the first-run pick: the roster is fetched, so this matters until the
-- list lands and the user chooses. Flash rather than Pro because an agent turn
-- is many requests and the free tier is metered per minute.
Gemini.DEFAULT_MODEL = "gemini-3.8-flash"

-- A local id for a call the model did not name. Gemini's functionCall.id is
-- optional and usually absent, but the harness pairs a tool_result to its
-- tool_use BY id, so one has to exist. Invented ids are stripped again on the
-- way out — see toContents — because the wire matches a response to its call by
-- name and order, and handing back an id the model never issued is a lie about
-- what it said.
local LOCAL_ID_PREFIX = "gmcall_"
local localIdCounter = 0

local function isLocalId(id: any): boolean
	return type(id) == "string" and id:sub(1, #LOCAL_ID_PREFIX) == LOCAL_ID_PREFIX
end

local function modelEntry(model: string): any?
	for _, entry in ipairs(Gemini.MODELS) do
		if entry.id == model then return entry end
	end
	return nil
end

-- Model list
local function contextHint(limit: any): string
	if type(limit) ~= "number" or limit <= 0 then return "" end
	if limit >= 1000000 then
		return string.format("%gM", limit / 1000000)
	end
	return string.format("%dk", math.floor(limit / 1000))
end

-- "models/gemini-2.5-flash" -> "gemini-2.5-flash". The resource name is what the
-- list returns; the bare id is what the URL and the settings slot want.
local function bareId(name: string): string
	return (name:gsub("^models/", ""))
end

-- "Gemini 2.5 Flash" -> "2.5 Flash". Every model here is a Gemini, so the word
-- is a column of padding on a chip that has none to spare.
local function shortName(displayName: string): string
	local trimmed = displayName:gsub("^Gemini%s+", "")
	return if trimmed ~= "" then trimmed else displayName
end

-- Speech, image, video and music models that nonetheless answer to
-- generateContent, which is why the method filter alone is not enough: asking
-- gemini-2.5-flash-preview-tts for a tool call gets a request for AUDIO
-- responseModalities, not a chat turn.
--
-- ponytail: a substring denylist, because the list endpoint publishes no
-- modality. Model, displayName and supportedGenerationMethods are all it
-- returns — there is no field here saying "this one speaks". So this reads the
-- id, which is a naming convention rather than a contract, and a family named
-- outside it slips through. The ceiling is one missed prefix; the upgrade path
-- is one more string here, or a real modality field if Google ever adds one.
local NON_TEXT: { string } = {
	"tts", "transcribe", "live", "audio", "image", "imagen",
	"veo", "lyria", "embedding", "robotics", "computer-use",
}

local function isTextModel(id: string): boolean
	local lower = id:lower()
	for _, mark in ipairs(NON_TEXT) do
		if lower:find(mark, 1, true) then return false end
	end
	return true
end

-- The ONE place a roster becomes Gemini.MODELS, and the reason it exists is that
-- there are two ways in: the fetch, and the day-old copy in plugin settings.
--
-- Filtering only on the way IN from the network was a bug with a long fuse. A
-- cache written by a build with a different filter — or none — goes on being
-- served for up to a day afterwards, so tightening the filter appears to do
-- nothing and the rows it was meant to remove are still there. Sorting had the
-- same hole. Both belong wherever the list is adopted, not where it is fetched.
local function applyRoster(entries: { any })
	local kept: { any } = {}
	for _, entry in ipairs(entries) do
		if type(entry) == "table" and type(entry.id) == "string" and isTextModel(entry.id) then
			kept[#kept + 1] = entry
		end
	end
	if #kept == 0 then return end
	-- Biggest window first, then id DESCENDING. The second key is a heuristic and
	-- worth naming as one: Google's ids sort so that a later series comes out on
	-- top ("gemini-3.8-flash" > "gemini-2.5-pro"), which is what puts something
	-- current in the four rows the picker draws before anyone types.
	table.sort(kept, function(a, b)
		local ac, bc = a.context or 0, b.context or 0
		if ac ~= bc then return ac > bc end
		return a.id > b.id
	end)
	Gemini.MODELS = kept
end

-- Fetches the roster, which is the only reason this provider needs no caps
-- table. Filtered twice: to the models that answer generateContent at all —
-- which drops the embedders, the legacy PaLM text and message methods and the
-- answer-only tuned models — and then to the ones that answer it with TEXT.
--
-- Needs the key — unlike NVIDIA's, this endpoint refuses unregistered callers —
-- so it runs after login rather than at Initialize on a fresh install.
--
-- Yields; call it from a task.spawn.
function refreshModels(): (boolean, string?)
	if not Auth then return false, "not initialized" end
	local key = Auth.getAccessToken()
	if not key then return false, "not logged in" end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = MODELS_URL,
			Method = "GET",
			Headers = {
				["x-goog-api-key"] = key,
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
	local data = (parsed :: any).models
	if type(data) ~= "table" then
		return false, "model list: no models array"
	end

	local out: { any } = {}
	for _, entry in ipairs(data) do
		local methods = entry.supportedGenerationMethods
		local usable = false
		if type(methods) == "table" then
			for _, method in ipairs(methods) do
				if method == "generateContent" then usable = true break end
			end
		end
		if usable and type(entry.name) == "string" and isTextModel(bareId(entry.name)) then
			local id = bareId(entry.name)
			local display = entry.displayName or id
			local hint = contextHint(entry.inputTokenLimit)
			if entry.thinking then
				hint = if hint ~= "" then hint .. " · reasoning" else "reasoning"
			end
			out[#out + 1] = {
				id = id,
				label = display,
				name = shortName(display),
				hint = if hint ~= "" then hint else nil,
				context = entry.inputTokenLimit,
				thinking = entry.thinking == true,
			}
		end
	end
	if #out == 0 then
		-- Never replace a working list with an empty one.
		return false, "model list: nothing that can generate content"
	end
	applyRoster(out)
	if plugin then
		pcall(function()
			-- Cached AFTER the filter and the sort, so the stored copy is already
			-- the list the picker wants. applyRoster runs on it again on the way
			-- back in anyway, which is what makes a cache from an older build safe.
			plugin:SetSetting(KEY_MODEL_CACHE, HttpService:JSONEncode(Gemini.MODELS))
			plugin:SetSetting(KEY_MODEL_CACHE_AT, os.time())
		end)
	end
	return true
end

local function Initialize(authModule: any, pluginRef: any)
	Auth = authModule
	plugin = pluginRef

	if plugin then
		local cached = plugin:GetSetting(KEY_MODEL_CACHE)
		if type(cached) == "string" and cached ~= "" then
			local ok, decoded = pcall(function() return HttpService:JSONDecode(cached) end)
			if ok and type(decoded) == "table" and #decoded > 0 then
				-- Through applyRoster, not straight onto MODELS: this copy may have
				-- been written by a build whose filter was looser than this one's.
				applyRoster(decoded)
			end
		end
		local at = plugin:GetSetting(KEY_MODEL_CACHE_AT)
		if type(at) ~= "number" or os.time() - at > MODEL_CACHE_MAX_AGE then
			task.spawn(refreshModels)
		end
	end
end

-- No slug here, unlike the other two OpenAI-shaped providers: a Gemini id is a
-- bare name with no vendor prefix. A `models/` prefix is accepted and stripped
-- because that is what the docs and the list endpoint print.
local function acceptsModelId(id: string): boolean
	local bare = bareId(id)
	return bare ~= "" and bare:match("^[%w%.%-_]+$") ~= nil
end

-- Outbound
local function resultText(content: any): string
	if type(content) == "string" then return content end
	if type(content) == "table" then
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

-- What the parser stashed in a thinking block's signature: the thought text, the
-- thought part's own signature, and call id -> signature for the function calls
-- in that same turn.
local function envelopeFrom(signature: string?): (string?, string?, { [string]: string })
	if type(signature) ~= "string" or signature == "" then return nil, nil, {} end
	local ok, env = pcall(function() return HttpService:JSONDecode(signature) end)
	if not ok or type(env) ~= "table" then return nil, nil, {} end
	local calls = (env :: any).f
	return (env :: any).t, (env :: any).s, if type(calls) == "table" then calls else {}
end

-- The whole conversation, converted. Returns a NEW array: `messages` is the live
-- table Agent appends to and Sessions persists, and writing request shaping into
-- it would leak onto the screen and into storage.
local function toContents(messages: { any }): { any }
	local out: { any } = {}
	-- functionResponse requires the function's name and a tool_result block does
	-- not carry one, so the walk remembers what each id was called.
	local nameById: { [string]: string } = {}

	for _, message in ipairs(messages) do
		local content = message.content

		if type(content) == "string" then
			out[#out + 1] = {
				role = if message.role == "assistant" then "model" else "user",
				parts = { { text = content } },
			}

		elseif type(content) == "table" and message.role == "user" then
			-- A tool_result batch. Anthropic packs them into one user message and
			-- so does this: parts are ordered, and the wire pairs a response to
			-- its call by name and position.
			local parts: { any } = {}
			local texts: { string } = {}
			for _, block in ipairs(content) do
				if block.type == "tool_result" then
					local id = block.tool_use_id
					parts[#parts + 1] = {
						functionResponse = {
							id = if isLocalId(id) then nil else id,
							name = nameById[id] or "unknown",
							-- `response` must be a JSON object; the tool produced a
							-- string. is_error rides along rather than being folded
							-- into the text, so the model can tell a failed call
							-- from one that returned the word "error".
							response = {
								output = resultText(block.content),
								error = if block.is_error then true else nil,
							},
						},
					}
				elseif block.type == "text" and block.text then
					texts[#texts + 1] = block.text
				end
			end
			if #texts > 0 then
				parts[#parts + 1] = { text = table.concat(texts, "\n") }
			end
			if #parts > 0 then
				out[#out + 1] = { role = "user", parts = parts }
			end

		elseif type(content) == "table" then
			-- The envelope has to be read before the parts are built: it lives on
			-- the thinking block, which comes first, but what it carries belongs to
			-- the functionCall parts after it.
			local thoughtText: string? = nil
			local thoughtSig: string? = nil
			local callSigs: { [string]: string } = {}
			for _, block in ipairs(content) do
				if block.type == "thinking" then
					thoughtText, thoughtSig, callSigs = envelopeFrom(block.signature)
					break
				end
			end

			local parts: { any } = {}
			if thoughtText and thoughtText ~= "" then
				-- Replayed as a thought part rather than plain text. The API does not
				-- enforce a signature here the way it does on a function call, but
				-- the documented advice is to hand the whole model turn back as it
				-- arrived, and a thought replayed as ordinary text would read as
				-- something the model said out loud.
				parts[#parts + 1] = {
					text = thoughtText,
					thought = true,
					thoughtSignature = thoughtSig,
				}
			end

			for _, block in ipairs(content) do
				if block.type == "text" and block.text and block.text ~= "" then
					parts[#parts + 1] = { text = block.text }
				elseif block.type == "tool_use" then
					nameById[block.id] = block.name
					local args = block.input
					parts[#parts + 1] = {
						functionCall = {
							id = if isLocalId(block.id) then nil else block.id,
							name = block.name,
							-- Omitted when empty: an empty Lua table encodes as `[]`
							-- and `args` is an object or absent, never a list.
							args = if type(args) == "table" and next(args) ~= nil then args else nil,
						},
						-- The mandatory one. Missing on the first functionCall of a
						-- step and Gemini 3 answers 400.
						thoughtSignature = callSigs[block.id],
					}
				end
			end

			if #parts > 0 then
				out[#out + 1] = { role = "model", parts = parts }
			end
		end
	end

	return out
end

local function toTools(tools: { any }?): { any }?
	if not tools or #tools == 0 then return nil end
	local declarations: { any } = {}
	for _, tool in ipairs(tools) do
		-- Anything without a name is a server tool from another provider; there is
		-- nothing to send for it here.
		if tool.name then
			declarations[#declarations + 1] = {
				name = tool.name,
				description = tool.description,
				-- parametersJsonSchema, NOT parameters. The latter is Gemini's own
				-- cut-down OpenAPI dialect and would need the harness's schemas
				-- translated into it; this field takes real JSON Schema, which is
				-- what Tools.luau already writes.
				parametersJsonSchema = tool.input_schema,
				-- eager_input_streaming is dropped: an Anthropic tool-definition
				-- flag, and there is nothing to force here — a functionCall part
				-- arrives whole rather than as argument fragments.
			}
		end
	end
	if #declarations == 0 then return nil end
	return { { functionDeclarations = declarations } }
end

-- Thinking is a property of the model, so it is read off the roster rather than
-- guessed. A model whose `thinking` is false, or one this list has never heard
-- of, gets no thinkingConfig at all: the field is documented to ERROR on a model
-- that does not support it, so silence is the only safe default.
local function applyThinking(generationConfig: { [string]: any }, model: string, effort: string?)
	local entry = modelEntry(model)
	if not (entry and entry.thinking) then return end
	generationConfig.thinkingConfig = {
		-- nil when no level is set, which leaves the model's own default.
		thinkingLevel = if effort then EFFORT_MAP[effort] else nil,
		-- Without this the thoughts are generated and billed but never sent, so
		-- the reasoning pane stays empty while thoughtsTokenCount climbs.
		includeThoughts = true,
	}
end

-- Rebased onto the shape Agent adds up.
--
-- promptTokenCount INCLUDES the cached part, the same way OpenAI-shaped usage
-- does and unlike Anthropic's input_tokens, so the cached half is subtracted
-- back out or every cached token is counted twice.
--
-- thoughtsTokenCount is the one that is easy to lose: it is NOT part of
-- candidatesTokenCount — the API's own total is prompt + thoughts + candidates —
-- so a thinking turn would report a fraction of what it actually spent, and the
-- output budget would never trip.
local function rebaseUsage(u: any): any?
	if type(u) ~= "table" then return nil end
	local cached = u.cachedContentTokenCount or 0
	local prompt = u.promptTokenCount or 0
	return {
		input_tokens = math.max(prompt - cached, 0),
		cache_read_input_tokens = cached,
		-- Implicit caching is automatic here and no field reports what was
		-- written, so this is honestly zero rather than a guess.
		cache_creation_input_tokens = 0,
		output_tokens = (u.candidatesTokenCount or 0) + (u.thoughtsTokenCount or 0),
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
		if callbacks.onError then callbacks.onError("Gemini module not initialized.") end
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

	local model = bareId(args.model or Gemini.DEFAULT_MODEL)

	local generationConfig: { [string]: any } = {}
	-- maxOutputTokens is deliberately NOT sent unless the caller asked for one.
	-- The documented default is the model's own outputTokenLimit, so naming it
	-- adds a number that can only be wrong. NVIDIA needed the opposite because
	-- its gateway defaults to 2048.
	if args.maxTokens then generationConfig.maxOutputTokens = args.maxTokens end
	applyThinking(generationConfig, model, args.effort)

	local bodyTable: { [string]: any } = {
		contents = toContents(args.messages),
	}
	if next(generationConfig) ~= nil then
		bodyTable.generationConfig = generationConfig
	end
	if args.system and args.system ~= "" then
		-- Its own field, not a message: `role` here is only ever user or model.
		bodyTable.systemInstruction = { parts = { { text = args.system } } }
	end

	local tools = toTools(args.tools)
	if tools then
		bodyTable.tools = tools
		bodyTable.toolConfig = { functionCallingConfig = { mode = "AUTO" } }
	end

	-- args.webSearch is ignored. Gemini does have a googleSearch tool, but it
	-- cannot be combined with functionDeclarations on every model, and a harness
	-- whose every capability is a tool call cannot trade those away for it.

	local bodyStr = HttpService:JSONEncode(bodyTable)
	local url = API_BASE .. "models/" .. model .. ":streamGenerateContent?alt=sse"

	-- Accumulators, rebuilt per attempt by `reset` below.
	local textAcc = ""
	local thoughtAcc = ""
	local thoughtSig: string? = nil
	local callSigs: { [string]: string } = {}
	local toolAcc: { any } = {}
	local usage: any = nil
	local finishReason: string? = nil
	local completed = false

	-- Normalised so Agent's diagnostics say something a person recognises. Note
	-- what is NOT here: Gemini reports STOP for a turn that ended in function
	-- calls, where OpenAI reports tool_calls, so "did it call a tool" is answered
	-- by whether any arrived rather than by this table.
	local FINISH = {
		STOP = "end_turn",
		MAX_TOKENS = "max_tokens",
		SAFETY = "safety",
		RECITATION = "recitation",
		MALFORMED_FUNCTION_CALL = "malformed_function_call",
		MISSING_THOUGHT_SIGNATURE = "missing_thought_signature",
	}

	local function assemble(): { any }
		local blocks: { any } = {}
		-- Emitted whenever there is anything to carry, INCLUDING when the thought
		-- text is empty and only signatures need to survive. Agent keeps a
		-- thinking block if it has a signature and drops it otherwise, and a
		-- dropped one here would take the function calls' signatures with it and
		-- fail the next turn with a 400.
		if thoughtAcc ~= "" or thoughtSig or next(callSigs) ~= nil then
			blocks[#blocks + 1] = {
				type = "thinking",
				thinking = thoughtAcc,
				signature = HttpService:JSONEncode({
					t = if thoughtAcc ~= "" then thoughtAcc else nil,
					s = thoughtSig,
					f = if next(callSigs) ~= nil then callSigs else nil,
				}),
			}
		end
		if textAcc ~= "" then
			blocks[#blocks + 1] = { type = "text", text = textAcc }
		end
		for _, slot in ipairs(toolAcc) do
			blocks[#blocks + 1] = {
				type = "tool_use",
				id = slot.id,
				name = slot.name,
				input = slot.raw,
				inputParsed = slot.args,
			}
		end
		return blocks
	end

	local function complete(ctrl: Stream.Ctrl)
		if completed then return end
		completed = true
		local blocks = assemble()
		-- Derived, not read: see FINISH above.
		local stopReason = if #toolAcc > 0
			then "tool_use"
			else (if finishReason then FINISH[finishReason] or finishReason else nil)
		ctrl.finish(function()
			if callbacks.onComplete then
				callbacks.onComplete({
					ok = true,
					text = if textAcc ~= "" then textAcc else nil,
					thinking = if thoughtAcc ~= "" then thoughtAcc else nil,
					usage = usage,
					stopReason = stopReason,
					contentBlocks = blocks,
				})
			end
		end)
	end

	local function readParts(parts: any, ctrl: Stream.Ctrl)
		for _, part in ipairs(parts) do
			if type(part) == "table" then
				local call = part.functionCall
				if type(call) == "table" and type(call.name) == "string" then
					-- A functionCall arrives WHOLE. There is no equivalent of
					-- OpenAI's argument fragments, so the block and its input land
					-- together rather than the header appearing first.
					local id = call.id
					if type(id) ~= "string" or id == "" then
						localIdCounter += 1
						id = LOCAL_ID_PREFIX .. tostring(localIdCounter)
					end
					local argsTable = if type(call.args) == "table" then call.args else {}
					local raw = "{}"
					if next(argsTable) ~= nil then
						local ok, encoded = pcall(function() return HttpService:JSONEncode(argsTable) end)
						if ok then raw = encoded end
					end
					toolAcc[#toolAcc + 1] = { id = id, name = call.name, args = argsTable, raw = raw }
					if type(part.thoughtSignature) == "string" and part.thoughtSignature ~= "" then
						callSigs[id] = part.thoughtSignature
					end
					ctrl.emitted()
					if callbacks.onToolUseStart then callbacks.onToolUseStart(id, call.name) end
					if callbacks.onToolInput then callbacks.onToolInput(id, raw) end

				elseif type(part.text) == "string" and part.text ~= "" then
					if part.thought then
						ctrl.emitted()
						thoughtAcc ..= part.text
						if callbacks.onThinking then callbacks.onThinking(part.text) end
					else
						ctrl.emitted()
						textAcc ..= part.text
						if callbacks.onText then callbacks.onText(part.text) end
					end
					if part.thought and type(part.thoughtSignature) == "string" then
						thoughtSig = part.thoughtSignature
					end

				elseif type(part.thoughtSignature) == "string" and part.thoughtSignature ~= "" then
					-- A signature with no content of its own. Documented: "the model
					-- may return the thought signature in a part with an empty text
					-- content part", and it is usually the last thing on the wire.
					-- Attached to the most recent call if there is one, so a turn
					-- whose signature trails its functionCall still replays.
					local last = toolAcc[#toolAcc]
					if last and not callSigs[last.id] then
						callSigs[last.id] = part.thoughtSignature
					else
						thoughtSig = part.thoughtSignature
					end
				end
			end
		end
	end

	local function onFrame(frame: string, ctrl: Stream.Ctrl)
		for line in frame:gmatch("[^\r\n]+") do
			if line:sub(1, 1) ~= ":" then
				local data = line:match("^data:%s*(.+)$")
				if data then
					local parsed
					if not pcall(function() parsed = HttpService:JSONDecode(data) end) then
						return
					end
					local chunk = parsed :: any

					if chunk.error then
						local err = chunk.error
						ctrl.fail(nil, data, string.format("stream error — %s",
							tostring(err.message or err.status or "unknown")))
						return
					end

					-- Read BEFORE the candidate below, which can finish the stream:
					-- usage rides on the same chunk that carries finishReason.
					if chunk.usageMetadata then
						usage = rebaseUsage(chunk.usageMetadata) or usage
					end

					local candidate = chunk.candidates and chunk.candidates[1]
					if candidate then
						local content = candidate.content
						if type(content) == "table" and type(content.parts) == "table" then
							readParts(content.parts, ctrl)
						end
						if candidate.finishReason then
							finishReason = candidate.finishReason
							if finishReason == "MISSING_THOUGHT_SIGNATURE" then
								-- Worth naming out loud: it means the envelope above
								-- lost a signature on the way back out, which is a bug
								-- here rather than anything the user did.
								warn("[agent] Gemini rejected the replayed history: a function call "
									.. "was missing its thought signature")
							end
							-- There is no [DONE] on this wire. The stream ends on the
							-- chunk carrying a finishReason and the socket closes after
							-- it, so this is the ordinary completion path and `closed`
							-- below is only the backstop.
							complete(ctrl)
							return
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
				url = url,
				headers = {
					-- The header form, not ?key= in the URL: a query string ends up
					-- in error text and logs, and this one does not.
					["x-goog-api-key"] = key :: string,
					["content-type"] = "application/json",
					["accept"] = "text/event-stream",
				},
				body = bodyStr,
			}
		end,

		reset = function()
			textAcc = ""
			thoughtAcc = ""
			thoughtSig = nil
			callSigs = {}
			toolAcc = {}
			usage = nil
			finishReason = nil
			completed = false
		end,

		frame = onFrame,

		-- A close with no finishReason. Anything already accumulated is delivered
		-- rather than thrown away.
		closed = function(ctrl: Stream.Ctrl)
			if finishReason or textAcc ~= "" or #toolAcc > 0 then
				complete(ctrl)
			end
		end,

		partial = function(): string?
			return if textAcc ~= "" then textAcc else nil
		end,

		explain = function(status: number?, body: string?): string?
			if status == 400 and body and body:find("API_KEY_INVALID", 1, true) then
				return "Google rejected the key. Two reasons are worth checking before the "
					.. "obvious one. Google retired Standard keys (the `AIza…` kind) in "
					.. "September 2026 in favour of auth keys (`AQ.…`), so an older key stops "
					.. "working without being deleted. And a key is bound to a project and can "
					.. "be restricted to particular APIs, so one that works elsewhere is refused "
					.. "here if Generative Language is not among them. A new key from "
					.. tostring(Auth and Auth.API_KEYS_URL) .. " is an auth key, and /code takes it."
			end
			if status == 429 then
				return "Rate limited. The free tier meters per MINUTE as well as per day, and "
					.. "an agent turn is many requests rather than one, so it arrives sooner "
					.. "here than in a chat window. A Flash model has a far higher ceiling "
					.. "than Pro; your live limits are on the AI Studio rate-limit page."
			end
			if status == 404 then
				return string.format(
					"No model called %q on this key. The picker's list is fetched from your "
					.. "own account, so anything in it will work; an id typed by hand may be "
					.. "preview-only or not enabled for your project.", model)
			end
			return nil
		end,

		-- No refresh hook: an AI Studio key does not expire on a schedule and
		-- cannot be renewed in place, so a 400 on it means it was deleted or
		-- restricted and asking again with the same one cannot help.
	}, {
		onError = callbacks.onError,
		onRetry = callbacks.onRetry,
	})
end

-- Self-test
-- Translation is most of this file and every way it can be wrong is quiet: a
-- lost thought signature 400s the NEXT turn rather than this one, an unresolved
-- functionResponse name desyncs the pairing, and thinking tokens dropped from
-- usage just make the panel read low.
local function selfTest(): (boolean, string?)
	-- A conversation exercising every block shape that reaches the wire, with a
	-- thinking block whose envelope carries a call signature.
	local envelope = HttpService:JSONEncode({
		t = "a summary", s = "SIG_THOUGHT", f = { call_1 = "SIG_CALL" },
	})
	local conversation = {
		{ role = "user", content = "hello" },
		{ role = "assistant", content = {
			{ type = "thinking", thinking = "a summary", signature = envelope },
			{ type = "text", text = "listing" },
			{ type = "tool_use", id = "call_1", name = "bash", input = { command = "ls" } },
		} },
		{ role = "user", content = {
			{ type = "tool_result", tool_use_id = "call_1", content = "Baseplate" },
		} },
	}
	local before = HttpService:JSONEncode(conversation)
	local out = toContents(conversation)

	if HttpService:JSONEncode(conversation) ~= before then
		return false, "toContents mutated the caller's conversation"
	end
	if #out ~= 3 then
		return false, string.format("expected 3 contents, got %d", #out)
	end
	if out[1].role ~= "user" or out[1].parts[1].text ~= "hello" then
		return false, "a plain user message did not convert"
	end

	-- assistant -> model, and the thought replayed as a thought.
	local modelTurn = out[2]
	if modelTurn.role ~= "model" then
		return false, "the assistant role did not become `model`"
	end
	if modelTurn.parts[1].thought ~= true or modelTurn.parts[1].text ~= "a summary" then
		return false, "the thought was not replayed as a thought part"
	end
	if modelTurn.parts[1].thoughtSignature ~= "SIG_THOUGHT" then
		return false, "the thought part lost its signature"
	end
	if modelTurn.parts[2].text ~= "listing" then
		return false, "assistant text did not convert"
	end
	local fc = modelTurn.parts[3].functionCall
	if not fc or fc.name ~= "bash" or fc.args.command ~= "ls" then
		return false, "a tool_use block did not become a functionCall"
	end
	-- The one that 400s the next turn if it regresses.
	if modelTurn.parts[3].thoughtSignature ~= "SIG_CALL" then
		return false, "the functionCall lost its thought signature"
	end

	-- tool_result -> functionResponse, with the NAME resolved from the call.
	local fr = out[3].parts[1].functionResponse
	if not fr or fr.name ~= "bash" then
		return false, "functionResponse did not resolve the function name"
	end
	if fr.id ~= "call_1" or fr.response.output ~= "Baseplate" then
		return false, "functionResponse did not carry the id and output"
	end
	if fr.response.error ~= nil then
		return false, "a successful tool result was marked as an error"
	end

	-- A model-issued id is replayed; one this file invented is not, because the
	-- wire pairs by name and order and never saw it.
	local localId = LOCAL_ID_PREFIX .. "7"
	local invented = toContents({
		{ role = "assistant", content = {
			{ type = "tool_use", id = localId, name = "bash", input = { command = "ls" } },
		} },
		{ role = "user", content = {
			{ type = "tool_result", tool_use_id = localId, content = "ok" },
		} },
	})
	if invented[1].parts[1].functionCall.id ~= nil then
		return false, "an invented call id was sent to the wire"
	end
	if invented[2].parts[1].functionResponse.id ~= nil then
		return false, "an invented call id was sent back in the response"
	end
	if invented[2].parts[1].functionResponse.name ~= "bash" then
		return false, "the name did not resolve for an invented id"
	end

	-- An empty input must be absent, not `[]`: args is an object or nothing.
	local emptyArgs = toContents({
		{ role = "assistant", content = {
			{ type = "tool_use", id = "c", name = "bash", input = {} },
		} },
	})
	if emptyArgs[1].parts[1].functionCall.args ~= nil then
		return false, "an empty tool input was sent as an args value"
	end

	-- An errored tool result says so.
	local errored = toContents({
		{ role = "assistant", content = {
			{ type = "tool_use", id = "c", name = "bash", input = { command = "x" } },
		} },
		{ role = "user", content = {
			{ type = "tool_result", tool_use_id = "c", content = "boom", is_error = true },
		} },
	})
	if errored[2].parts[1].functionResponse.response.error ~= true then
		return false, "is_error did not survive into the functionResponse"
	end

	-- Tool definitions: JSON Schema goes through as parametersJsonSchema, and the
	-- Anthropic-only streaming flag does not ride along.
	local wireTools = toTools({
		{ name = "bash", description = "run", input_schema = { type = "object" }, eager_input_streaming = true },
	})
	if not wireTools or not wireTools[1].functionDeclarations then
		return false, "a tool definition did not convert"
	end
	local decl = wireTools[1].functionDeclarations[1]
	if decl.name ~= "bash" or decl.parametersJsonSchema == nil then
		return false, "the tool schema did not become parametersJsonSchema"
	end
	if (decl :: any).parameters ~= nil then
		return false, "the cut-down OpenAPI field was sent as well as the JSON Schema one"
	end
	if (decl :: any).eager_input_streaming ~= nil then
		return false, "an Anthropic-only tool flag was sent to Gemini"
	end

	-- Thinking is gated on the roster's flag, and the five-into-four squeeze.
	local restore = Gemini.MODELS
	Gemini.MODELS = {
		{ id = "thinks", label = "T", name = "T", thinking = true, context = 1048576 },
		{ id = "plain", label = "P", name = "P", thinking = false },
	}
	local cfg: { [string]: any } = {}
	applyThinking(cfg, "thinks", "xhigh")
	if not cfg.thinkingConfig or cfg.thinkingConfig.thinkingLevel ~= "HIGH" then
		return false, "xhigh did not map onto a level the enum has"
	end
	if cfg.thinkingConfig.includeThoughts ~= true then
		return false, "thoughts were not requested, so none would ever render"
	end
	local plainCfg: { [string]: any } = {}
	applyThinking(plainCfg, "plain", "high")
	if next(plainCfg) ~= nil then
		return false, "thinkingConfig was sent to a model that does not support it"
	end
	local unknownCfg: { [string]: any } = {}
	applyThinking(unknownCfg, "never-heard-of-it", "high")
	if next(unknownCfg) ~= nil then
		return false, "thinkingConfig was sent to a model with no roster entry"
	end
	if Gemini.contextWindow("thinks") ~= 1048576 then
		return false, "contextWindow did not read inputTokenLimit"
	end
	if Gemini.contextWindow("plain") ~= nil then
		return false, "a context window was invented for a model with no limit"
	end
	Gemini.MODELS = restore

	-- Usage. The thoughts term is the one that silently under-reports.
	local u = rebaseUsage({
		promptTokenCount = 120,
		cachedContentTokenCount = 20,
		candidatesTokenCount = 30,
		thoughtsTokenCount = 45,
		totalTokenCount = 195,
	})
	if not u or u.input_tokens ~= 100 or u.cache_read_input_tokens ~= 20 then
		return false, "prompt tokens were not rebased off the cached half"
	end
	if u.output_tokens ~= 75 then
		return false, "thinking tokens were left out of the output count"
	end

	-- The roster filter. generateContent alone is not enough: the speech, image
	-- and music models answer to it too, and they were turning up in the picker.
	for _, id in ipairs({ "gemini-3.8-flash", "gemini-2.5-pro", "gemini-3.1-flash-lite" }) do
		if not isTextModel(id) then
			return false, "a text chat model was filtered out of the roster: " .. id
		end
	end
	for _, id in ipairs({
		"gemini-2.5-flash-preview-tts", "gemini-3.5-transcribe",
		"gemini-2.5-flash-native-audio-preview-12-2025", "gemini-3.1-flash-live-preview",
		"gemini-3-pro-image", "veo-3.1-generate-preview", "lyria-3.5",
		"gemini-embedding-001", "gemini-robotics-er-2-preview",
	}) do
		if isTextModel(id) then
			return false, "a non-text model reached the roster: " .. id
		end
	end

	if bareId("models/gemini-2.5-flash") ~= "gemini-2.5-flash" then
		return false, "bareId did not strip the resource prefix"
	end
	if shortName("Gemini 2.5 Flash") ~= "2.5 Flash" then
		return false, "shortName: got " .. shortName("Gemini 2.5 Flash")
	end
	if not acceptsModelId("gemini-2.5-flash") or not acceptsModelId("models/gemini-2.5-flash") then
		return false, "acceptsModelId rejected a real id"
	end
	if acceptsModelId("anthropic/claude-sonnet-5") then
		return false, "acceptsModelId accepted another provider's slug"
	end

	return true
end

-- The input window for a model id, for the settings panel's context row. Read
-- off the fetched roster's inputTokenLimit, which is the model's own published
-- number rather than anything written down here.
--
-- nil when the roster has not landed yet: the seed above carries no limits, and
-- a made-up denominator turns a progress bar into a confident wrong reading.
function Gemini.contextWindow(model: string): number?
	local entry = modelEntry(bareId(model))
	local context = entry and entry.context
	return if type(context) == "number" and context > 0 then context else nil
end

Gemini.Initialize = Initialize
Gemini.streamMessage = streamMessage
Gemini.acceptsModelId = acceptsModelId
Gemini.refreshModels = refreshModels
Gemini.selfTest = selfTest
-- Exported for the offline test harness only: the roster filter is a heuristic
-- and the matrix of ids it has to get right is longer than a selfTest wants.
Gemini._isTextModel = isTextModel

return Gemini
