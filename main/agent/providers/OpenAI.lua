--!strict
--!optimize 2
-- OpenAI.luau: account-backed Codex Responses client, one request, SSE back.
--
-- The plugin keeps one provider-neutral-enough history shape: Anthropic content
-- blocks. This module translates that shape to Responses input items and turns
-- streamed Responses output items back into the same blocks. Agent, Sessions,
-- Find and Console therefore do not learn another protocol.
--
-- Responses reasoning items are the important part of the translation. With
-- store=false, OpenAI returns encrypted reasoning content when requested and
-- requires the item and its paired following output back on later turns. A
-- thinking block's signature is already an opaque provider-owned string, so it
-- carries that complete output sequence without leaking wire state into Agent.
--
-- Reference: https://developers.openai.com/api/reference/cli/resources/responses/methods/create

local HttpService = game:GetService("HttpService")
local warn = warn

local Stream = require(script.Parent:WaitForChild("Stream"))
local ToolJson = require(script.Parent:WaitForChild("ToolJson"))
local Retry = require(script.Parent:WaitForChild("Retry"))

local OpenAI = {}
local Auth: any = nil

-- ChatGPT/Codex subscription traffic. Deliberately never fall back to
-- api.openai.com: that is separately billed Platform API usage.
local RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses"

-- Curated rather than fetched. GET /models only returns identifiers and owners,
-- not whether an id supports Responses, function calling, reasoning, or web
-- search, so turning it directly into a picker would offer unusable audio,
-- image and embedding models. `/model <id>` still allows another compatible id.
OpenAI.MODELS = {
	{ id = "gpt-6-astra", label = "GPT-6 Astra", name = "GPT-6 Astra", hint = "most capable · 1.05M", context = 1050000 },
	{ id = "gpt-5.6-sol", label = "GPT-5.6 Sol", name = "GPT-5.6 Sol", hint = "flagship · 1.05M", context = 1050000 },
	{ id = "gpt-5.6-terra", label = "GPT-5.6 Terra", name = "GPT-5.6 Terra", hint = "balanced · 1.05M", context = 1050000 },
	{ id = "gpt-5.6-luna", label = "GPT-5.6 Luna", name = "GPT-5.6 Luna", hint = "cost-sensitive · 1.05M", context = 1050000 },
}
OpenAI.DEFAULT_MODEL = "gpt-6-astra"

local function Initialize(authModule: any)
	Auth = authModule
end

local function acceptsModelId(id: string): boolean
	if type(id) ~= "string" or id == "" or id:find("%s") then return false end
	return id:match("^gpt%-") ~= nil
		or id:match("^o%d") ~= nil
		or id:match("^chatgpt%-") ~= nil
		or id:match("^codex%-") ~= nil
		or id:match("^ft:") ~= nil
end

function OpenAI.contextWindow(model: string): number?
	for _, entry in ipairs(OpenAI.MODELS) do
		if entry.id == model then return entry.context end
	end
	return nil
end

local function supportsReasoning(model: string): boolean
	return model:match("^gpt%-[56]") ~= nil or model:match("^o%d") ~= nil
end

local function toolArguments(input: any): string
	if type(input) ~= "table" or next(input) == nil then return "{}" end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(input) end)
	return if ok then encoded else "{}"
end

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

local function reasoningEnvelope(signature: string?): (any?, { any }?, string?)
	if type(signature) ~= "string" or signature == "" then return nil, nil, nil end
	local ok, envelope = pcall(function() return HttpService:JSONDecode(signature) end)
	if not ok or type(envelope) ~= "table" then return nil, nil, nil end
	local output = if type((envelope :: any).output) == "table"
		then (envelope :: any).output else nil
	local item = (envelope :: any).item
	if type(item) ~= "table" and output then
		local index = tonumber((envelope :: any).reasoning_index)
		item = index and output[index] or nil
	end
	if type(item) == "table" and item.type == "reasoning" then
		local model = if type((envelope :: any).model) == "string"
			then (envelope :: any).model else nil
		return item, output, model
	end
	-- Accept a raw item too, so a future simplification of the envelope does not
	-- make sessions written by that build unreadable by this one.
	if (envelope :: any).type == "reasoning" then return envelope, nil, nil end
	return nil, nil, nil
end

local function reasoningItem(signature: string?, model: string?): any?
	local item, _, sourceModel = reasoningEnvelope(signature)
	-- Encrypted reasoning is model-bound. If the reader changes models inside an
	-- OpenAI session, preserve the visible summary but do not send ciphertext the
	-- new model cannot decrypt.
	if sourceModel and model and sourceModel ~= model then return nil end
	return item
end

local function isServerResult(block: any): boolean
	return type(block.type) == "string" and block.type:sub(-12) == "_tool_result"
end

-- Convert the complete local conversation to stateless Responses input items.
-- Returns a fresh tree; request shaping must never mutate the live session.
local function toResponseInput(messages: { any }, model: string?): { any }
	local out: { any } = {}

	local function appendMessage(role: string, parts: { string })
		if #parts == 0 then return end
		out[#out + 1] = { role = role, content = table.concat(parts, "\n") }
		table.clear(parts)
	end

	for _, message in ipairs(messages) do
		local content = message.content
		if type(content) == "string" then
			out[#out + 1] = { role = message.role, content = content }
		elseif type(content) == "table" and message.role == "user" then
			local textParts: { string } = {}
			for _, block in ipairs(content) do
				if block.type == "tool_result" then
					appendMessage("user", textParts)
					out[#out + 1] = {
						type = "function_call_output",
						call_id = block.tool_use_id,
						output = resultText(block.content),
					}
				elseif block.type == "text" and type(block.text) == "string" then
					textParts[#textParts + 1] = block.text
				end
			end
			appendMessage("user", textParts)
		elseif type(content) == "table" then
			-- OpenAI pairs a reasoning item with the output item that followed it.
			-- Replaying only the encrypted reasoning shell and rebuilding that next
			-- message loses its server id and can be rejected as an orphan. The first
			-- thinking signature therefore carries the complete original output list.
			local preservedOutput: { any }? = nil
			for _, block in ipairs(content) do
				if block.type == "thinking" then
					local _, output, sourceModel = reasoningEnvelope(block.signature)
					if output and (not sourceModel or not model or sourceModel == model) then
						preservedOutput = output
						break
					end
				end
			end
			if preservedOutput then
				for _, item in ipairs(preservedOutput) do out[#out + 1] = item end
			else
				local textParts: { string } = {}
				for _, block in ipairs(content) do
					if block.type == "text" and type(block.text) == "string" then
						textParts[#textParts + 1] = block.text
					elseif block.type == "thinking" then
						appendMessage("assistant", textParts)
						local item = reasoningItem(block.signature, model)
						if item then out[#out + 1] = item end
					elseif block.type == "tool_use" then
						appendMessage("assistant", textParts)
						-- Codex puts the exact ResponseItem back into the next
						-- sampling request. Most turns preserve the whole output in
						-- the reasoning envelope above, but a function-only response
						-- has no such envelope. Keep its provider-owned item on the
						-- neutral block so ids/status survive that path as well.
						local state = block.providerState
						local exact = type(state) == "table" and state.provider == "openai"
							and state.item or nil
						if type(exact) == "table" and exact.type == "function_call" then
							out[#out + 1] = exact
						else
							out[#out + 1] = {
								type = "function_call",
								call_id = block.id,
								name = block.name,
								arguments = toolArguments(block.input),
							}
						end
					elseif isServerResult(block) then
						appendMessage("assistant", textParts)
						local item = block._openai_item
						if type(item) == "table" then out[#out + 1] = item end
					end
					-- server_tool_use is the display half of an OpenAI hosted-tool
					-- item. Its paired *_tool_result owns and replays the raw item.
				end
				appendMessage("assistant", textParts)
			end
		end
	end
	return out
end

local function toResponseTools(tools: { any }?, webSearch: number?): { any }?
	local out: { any } = {}
	for _, tool in ipairs(tools or {}) do
		if tool.name then
			out[#out + 1] = {
				type = "function",
				name = tool.name,
				description = tool.description,
				parameters = tool.input_schema,
				-- ToolJson and Agent deliberately recover partial JSON. Strict
				-- schema mode would reject those calls before that recovery can run.
				strict = false,
			}
		end
	end
	if webSearch and webSearch > 0 then
		out[#out + 1] = { type = "web_search" }
	end
	return if #out > 0 then out else nil
end

local function reasoningText(item: any): string
	local parts: { string } = {}
	for _, part in ipairs(type(item.summary) == "table" and item.summary or {}) do
		if type(part) == "table" and type(part.text) == "string" then
			parts[#parts + 1] = part.text
		end
	end
	for _, part in ipairs(type(item.content) == "table" and item.content or {}) do
		if type(part) == "table" and type(part.text) == "string" then
			parts[#parts + 1] = part.text
		end
	end
	return table.concat(parts, "\n")
end

local function serverContent(item: any): any
	if type(item.action) == "table" then return item.action end
	if type(item.results) == "table" then return item.results end
	return { status = item.status or "completed" }
end

local function rebaseUsage(u: any): any?
	if type(u) ~= "table" then return nil end
	local details = type(u.input_tokens_details) == "table" and u.input_tokens_details or {}
	local cached = tonumber(details.cached_tokens) or 0
	local written = tonumber(details.cache_write_tokens) or 0
	local total = tonumber(u.input_tokens) or 0
	return {
		input_tokens = math.max(total - cached - written, 0),
		cache_read_input_tokens = cached,
		cache_creation_input_tokens = written,
		output_tokens = tonumber(u.output_tokens) or 0,
	}
end

local function failureStatus(err: any): number?
	local code = type(err) == "table" and err.code or nil
	if code == "rate_limit_exceeded" then return 429 end
	if code == "server_is_overloaded" or code == "slow_down" then return 503 end
	return nil
end

-- Codex's turn loop has two independent reasons to sample again: a function
-- call was emitted, or the completed response explicitly says `end_turn=false`.
-- The latter can be an empty bridge response after tool output, so inferring
-- completion only from output items makes a valid Codex turn stop silently.
local function responseStopReason(response: any, hasFunction: boolean,
	forcedStop: string?): string
	if forcedStop then return forcedStop end
	if hasFunction then return "tool_use" end
	if type(response) == "table" and response.end_turn == false then
		return "continue_turn"
	end
	return "end_turn"
end

-- The ChatGPT Codex stream has two representations of output: incremental
-- output_item events and the response.completed payload. The latter is normally
-- complete, but gateways are allowed to omit its output array after already
-- streaming the items. Throwing the streamed copy away makes tools run on screen
-- yet disappear from history, so Agent sees no function call and ends the turn.
local function completedOutput(response: any, streamed: { any }): { any }
	local final = if type(response) == "table" and type(response.output) == "table"
		then response.output else nil
	if not final or #final == 0 then return streamed end
	if #streamed == 0 then return final end

	-- Preserve final-event fields where present and fill holes from the streamed
	-- item at the same output_index. Some relays leave `arguments`, `content` or a
	-- whole trailing item empty in the final envelope even though its done event
	-- was complete.
	local merged: { any } = {}
	for index = 1, math.max(#final, #streamed) do
		local finalItem = final[index]
		local streamedItem = streamed[index]
		if type(finalItem) == "table" and type(streamedItem) == "table"
			and finalItem.type == streamedItem.type then
			local item = table.clone(finalItem)
			for key, value in pairs(streamedItem) do
				local current = item[key]
				if current == nil or current == ""
					or (type(current) == "table" and next(current) == nil) then
					item[key] = value
				end
			end
			merged[index] = item
		else
			merged[index] = finalItem or streamedItem
		end
	end
	return merged
end

local function needsTokenRefresh(status: number?, _body: string?): boolean
	return status == 401
end

local function rateLimitResetSeconds(headers: string?): number?
	local primary = Retry.resetSeconds(headers, "x-codex-primary-reset-at")
	local secondary = Retry.resetSeconds(headers, "x-codex-secondary-reset-at")
	if primary and secondary then return math.max(primary, secondary) end
	return primary or secondary
end

local function assemble(output: any, fallbackText: string, model: string?): ({ any }, boolean)
	local blocks: { any } = {}
	local hasFunction = false
	local responseOutput = type(output) == "table" and output or {}
	local outputCaptured = false
	for index, item in ipairs(responseOutput) do
		if item.type == "reasoning" then
			local envelope: { [string]: any }
			if not outputCaptured then
				-- Codex preserves every ResponseItem for the next request. Agent's
				-- provider-owned signature is the one opaque field that survives its
				-- internal block conversion, so keep that exact output sequence here.
				envelope = { output = responseOutput, reasoning_index = index, model = model }
				outputCaptured = true
			else
				envelope = { item = item, model = model }
			end
			blocks[#blocks + 1] = {
				type = "thinking",
				thinking = reasoningText(item),
				signature = HttpService:JSONEncode(envelope),
			}
		elseif item.type == "message" then
			for _, part in ipairs(type(item.content) == "table" and item.content or {}) do
				if part.type == "output_text" and type(part.text) == "string" and part.text ~= "" then
					blocks[#blocks + 1] = {
						type = "text",
						text = part.text,
						citations = part.annotations,
					}
				elseif part.type == "refusal" and type(part.refusal) == "string" then
					blocks[#blocks + 1] = { type = "text", text = part.refusal }
				end
			end
		elseif item.type == "function_call" then
			hasFunction = true
			local arguments = type(item.arguments) == "string" and item.arguments or ""
			local parsed, repaired = ToolJson.decode(arguments)
			if repaired then
				warn(string.format("[agent] %s: repaired unescaped control characters in tool input",
					tostring(item.name)))
			end
			blocks[#blocks + 1] = {
				type = "tool_use",
				id = item.call_id or item.id,
				name = item.name,
				input = arguments,
				inputParsed = parsed,
				providerState = { provider = "openai", item = item },
			}
		elseif item.type == "web_search_call" then
			local id = item.id
			local content = serverContent(item)
			blocks[#blocks + 1] = {
				type = "server_tool_use",
				id = id,
				name = "web_search",
				input = content,
				inputParsed = content,
			}
			blocks[#blocks + 1] = {
				type = "web_search_tool_result",
				raw = {
					type = "web_search_tool_result",
					tool_use_id = id,
					content = content,
					_openai_item = item,
				},
			}
		end
	end
	if #blocks == 0 and fallbackText ~= "" then
		blocks[1] = { type = "text", text = fallbackText }
	end
	return blocks, hasFunction
end

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
		if callbacks.onError then callbacks.onError("OpenAI module not initialized.") end
		return noopHandle()
	end
	if not args or type(args.messages) ~= "table" or #args.messages == 0 then
		if callbacks.onError then callbacks.onError("messages array is required and must be non-empty.") end
		return noopHandle()
	end
	local firstToken, tokenErr = Auth.getAccessToken()
	if not firstToken then
		if callbacks.onError then callbacks.onError("Auth: " .. tostring(tokenErr)) end
		return noopHandle()
	end
	if not Auth.getAccountId() then
		if callbacks.onError then callbacks.onError("Auth: ChatGPT account ID is missing. Use /logout, then /login.") end
		return noopHandle()
	end

	local model = args.model or OpenAI.DEFAULT_MODEL
	local bodyTable: { [string]: any } = {
		model = model,
		stream = true,
		store = false,
		include = { "reasoning.encrypted_content" },
		input = toResponseInput(args.messages, model),
		parallel_tool_calls = true,
	}
	if args.system and args.system ~= "" then bodyTable.instructions = args.system end
	if args.effort and args.effort ~= "" and supportsReasoning(model) then
		bodyTable.reasoning = { effort = args.effort, summary = "auto" }
	end
	local tools = toResponseTools(args.tools, args.webSearch)
	if tools then
		bodyTable.tools = tools
		bodyTable.tool_choice = "auto"
	end
	if args.webSearch and args.webSearch > 0 then
		-- The account-backed Codex endpoint enables hosted search by the tool's
		-- presence but rejects the public Responses `max_tool_calls` parameter.
		-- Treat the shared numeric setting as an enable switch on this provider;
		-- the other providers retain their own hard per-message ceilings.
		table.insert(bodyTable.include, "web_search_call.action.sources")
	end
	local bodyStr = HttpService:JSONEncode(bodyTable)

	local textAcc = ""
	local thinkingAcc = ""
	local slots: { any } = {}
	local byItemId: { [string]: any } = {}
	local completed = false

	local function slotFor(event: any): any
		local index = (tonumber(event.output_index) or 0) + 1
		local slot = slots[index]
		if not slot then
			slot = { index = index, item = nil, arguments = "", text = "", thinking = "",
				announced = false, serverStarted = false, serverFinished = false }
			slots[index] = slot
		end
		if type(event.item_id) == "string" then byItemId[event.item_id] = slot end
		return slot
	end

	local function announceFunction(slot: any, ctrl: Stream.Ctrl)
		local item = slot.item
		if slot.announced or type(item) ~= "table" or item.type ~= "function_call"
			or type(item.name) ~= "string" then return end
		slot.announced = true
		ctrl.emitted()
		if callbacks.onToolUseStart then callbacks.onToolUseStart(item.call_id or item.id, item.name) end
	end

	local function startServer(slot: any, ctrl: Stream.Ctrl)
		local item = slot.item
		if slot.serverStarted or type(item) ~= "table" or item.type ~= "web_search_call" then return end
		slot.serverStarted = true
		ctrl.emitted()
		if callbacks.onServerToolUse then
			callbacks.onServerToolUse("web_search", item.id, serverContent(item))
		end
	end

	local function finishServer(slot: any, ctrl: Stream.Ctrl)
		local item = slot.item
		if slot.serverFinished or type(item) ~= "table" or item.type ~= "web_search_call" then return end
		startServer(slot, ctrl)
		slot.serverFinished = true
		if callbacks.onServerToolResult then
			callbacks.onServerToolResult("web_search", item.id, serverContent(item))
		end
	end

	local function outputFromSlots(): { any }
		local output: { any } = {}
		for _, slot in ipairs(slots) do
			local item = slot.item
			if type(item) == "table" then
				if item.type == "function_call" and (not item.arguments or item.arguments == "") then
					item.arguments = slot.arguments
				elseif item.type == "message" and slot.text ~= ""
					and (type(item.content) ~= "table" or #item.content == 0) then
					item.content = { { type = "output_text", text = slot.text, annotations = {} } }
				elseif item.type == "reasoning" and slot.thinking ~= ""
					and (type(item.summary) ~= "table" or #item.summary == 0) then
					item.summary = { { type = "summary_text", text = slot.thinking } }
				end
				output[#output + 1] = item
			end
		end
		return output
	end

	local function complete(ctrl: Stream.Ctrl, response: any?, forcedStop: string?)
		if completed then return end
		completed = true
		-- The completed response is the authoritative full object. output_item.done
		-- populates the same data in slots and is the fallback for proxies that omit
		-- the output array from their final event.
		local output = completedOutput(response, outputFromSlots())

		-- A compliant stream announces these earlier. Doing it again here only for
		-- missing events keeps the tool loop usable through proxies that coalesce
		-- the stream down to its final event.
		for index, item in ipairs(output) do
			local slot = slots[index] or {
				item = item, announced = false, serverStarted = false, serverFinished = false,
			}
			slot.item = item
			if item.type == "function_call" then announceFunction(slot, ctrl) end
			if item.type == "web_search_call" then finishServer(slot, ctrl) end
		end

		local blocks, hasFunction = assemble(output, textAcc, model)
		local stopReason = responseStopReason(response, hasFunction, forcedStop)
		local usage = if type(response) == "table" then rebaseUsage(response.usage) else nil
		ctrl.finish(function()
			if callbacks.onComplete then
				callbacks.onComplete({
					ok = true,
					text = if textAcc ~= "" then textAcc else nil,
					thinking = if thinkingAcc ~= "" then thinkingAcc else nil,
					usage = usage,
					stopReason = stopReason,
					contentBlocks = blocks,
					-- Unlike message-based APIs, Codex may complete a bridge
					-- response without a visible output item. Agent must not invent
					-- an assistant message for it; Codex itself records only the
					-- ResponseItems that actually arrived.
					omitEmpty = true,
				})
			end
		end)
	end

	local function failEvent(ctrl: Stream.Ctrl, event: any, raw: string)
		local err = type(event.error) == "table" and event.error or event
		ctrl.fail(failureStatus(err), raw,
			"stream error — " .. tostring(err.message or err.code or event.type))
	end

	local function onEvent(event: any, raw: string, ctrl: Stream.Ctrl)
		local kind = event.type
		if kind == "response.output_item.added" then
			local slot = slotFor(event)
			slot.item = event.item
			if type(event.item) == "table" and type(event.item.id) == "string" then
				byItemId[event.item.id] = slot
			end
			announceFunction(slot, ctrl)
			startServer(slot, ctrl)
		elseif kind == "response.function_call_arguments.delta" then
			local slot = byItemId[event.item_id] or slotFor(event)
			local delta = type(event.delta) == "string" and event.delta or ""
			if delta ~= "" then
				slot.arguments ..= delta
				announceFunction(slot, ctrl)
				local item = slot.item
				if slot.announced and callbacks.onToolInput then
					callbacks.onToolInput(item and (item.call_id or item.id), delta)
				end
			end
		elseif kind == "response.function_call_arguments.done" then
			-- Usually redundant with the deltas and output_item.done, but it is the
			-- authoritative complete JSON when an intermediary coalesces deltas.
			local slot = byItemId[event.item_id] or slotFor(event)
			if type(event.arguments) == "string" then slot.arguments = event.arguments end
		elseif kind == "response.output_text.delta" or kind == "response.refusal.delta" then
			local slot = byItemId[event.item_id] or slotFor(event)
			local delta = type(event.delta) == "string" and event.delta or ""
			if delta ~= "" then
				ctrl.emitted()
				slot.text ..= delta
				textAcc ..= delta
				if callbacks.onText then callbacks.onText(delta) end
			end
		elseif kind == "response.reasoning_summary_text.delta"
			or kind == "response.reasoning_text.delta" then
			local slot = byItemId[event.item_id] or slotFor(event)
			local delta = type(event.delta) == "string" and event.delta or ""
			if delta ~= "" then
				ctrl.emitted()
				slot.thinking ..= delta
				thinkingAcc ..= delta
				if callbacks.onThinking then callbacks.onThinking(delta) end
			end
		elseif kind == "response.output_item.done" then
			local slot = slotFor(event)
			slot.item = event.item
			if type(event.item) == "table" and type(event.item.id) == "string" then
				byItemId[event.item.id] = slot
			end
			announceFunction(slot, ctrl)
			finishServer(slot, ctrl)
		elseif kind == "response.completed" then
			complete(ctrl, event.response, nil)
		elseif kind == "response.incomplete" then
			local response = event.response
			local reason = type(response) == "table" and type(response.incomplete_details) == "table"
				and response.incomplete_details.reason or "incomplete"
			complete(ctrl, response, reason == "max_output_tokens" and "max_tokens" or tostring(reason))
		elseif kind == "response.failed" or kind == "error" or kind == "response.error" then
			failEvent(ctrl, event.response or event, raw)
		elseif kind == "codex.rate_limits" then
			Auth.updateUsage(event)
		end
	end

	local function onFrame(frame: string, ctrl: Stream.Ctrl)
		local eventName: string? = nil
		local dataParts: { string } = {}
		for line in frame:gmatch("[^\r\n]+") do
			if line:sub(1, 1) ~= ":" then
				eventName = line:match("^event:%s*(.+)$") or eventName
				local data = line:match("^data:%s?(.*)$")
				if data then dataParts[#dataParts + 1] = data end
			end
		end
		if #dataParts == 0 then return end
		local raw = table.concat(dataParts, "\n")
		if raw == "[DONE]" then
			complete(ctrl, nil, nil)
			return
		end
		local parsed
		if not pcall(function() parsed = HttpService:JSONDecode(raw) end) then return end
		if type(parsed) ~= "table" then return end
		if not (parsed :: any).type and eventName then (parsed :: any).type = eventName end
		onEvent(parsed, raw, ctrl)
	end

	return Stream.open({
		request = function()
			local token, attemptErr = Auth.getAccessToken()
			if not token then return nil, "Auth: " .. tostring(attemptErr) end
			local accountId = Auth.getAccountId()
			if not accountId then return nil, "Auth: ChatGPT account ID is missing." end
			local headers = {
				["Authorization"] = "Bearer " .. (token :: string),
				["ChatGPT-Account-ID"] = accountId,
				["content-type"] = "application/json",
				["accept"] = "text/event-stream",
			}
			if Auth.isFedramp() then headers["X-OpenAI-Fedramp"] = "true" end
			return {
				url = RESPONSES_URL,
				headers = headers,
				body = bodyStr,
			}
		end,
		reset = function()
			textAcc = ""
			thinkingAcc = ""
			slots = {}
			byItemId = {}
			completed = false
		end,
		frame = onFrame,
		opened = function(_status: number, headers: string)
			Auth.updateUsageHeaders(headers)
		end,
		closed = function(ctrl: Stream.Ctrl)
			if textAcc ~= "" or #slots > 0 then complete(ctrl, nil, nil) end
		end,
		partial = function(): string?
			return if textAcc ~= "" then textAcc else nil
		end,
		explain = function(status: number?, _body: string?): string?
			if status == 401 then
				return "The ChatGPT session expired or was revoked. Use /logout, then sign in again with /login."
			elseif status == 403 then
				return "This ChatGPT account or workspace is not entitled to the requested Codex model or feature."
			elseif status == 404 then
				return "The selected model is unavailable to this ChatGPT account. Choose another model with /model."
			end
			return nil
		end,
		refresh = function()
			Auth.refresh()
		end,
		needsRefresh = needsTokenRefresh,
		windowReset = rateLimitResetSeconds,
	}, {
		onError = callbacks.onError,
		onRetry = callbacks.onRetry,
	})
end

local function selfTest(): (boolean, string?)
	local retryOk, retryErr = Retry.selfTest()
	if not retryOk then return false, "Retry: " .. tostring(retryErr) end
	local jsonOk, jsonErr = ToolJson.selfTest()
	if not jsonOk then return false, "ToolJson: " .. tostring(jsonErr) end

	local rawReasoning = {
		type = "reasoning",
		id = "rs_1",
		encrypted_content = "opaque",
		summary = { { type = "summary_text", text = "checked" } },
	}
	local conversation = {
		{ role = "user", content = "hello" },
		{ role = "assistant", content = {
			{ type = "thinking", thinking = "checked",
				signature = HttpService:JSONEncode({ item = rawReasoning }) },
			{ type = "text", text = "running" },
			{ type = "tool_use", id = "call_1", name = "bash", input = { command = "ls" } },
		} },
		{ role = "user", content = {
			{ type = "tool_result", tool_use_id = "call_1", content = "Baseplate" },
		} },
	}
	local before = HttpService:JSONEncode(conversation)
	local input = toResponseInput(conversation, "gpt-6-astra")
	if HttpService:JSONEncode(conversation) ~= before then
		return false, "toResponseInput mutated the caller's conversation"
	end
	if #input ~= 5 or input[1].role ~= "user" or input[2].type ~= "reasoning"
		or input[3].role ~= "assistant" or input[4].type ~= "function_call"
		or input[5].type ~= "function_call_output" then
		return false, "conversation did not become the expected Responses item sequence"
	end
	if input[2].encrypted_content ~= "opaque" then
		return false, "encrypted reasoning did not survive the signature envelope"
	end
	if input[4].call_id ~= "call_1" or input[5].call_id ~= "call_1" then
		return false, "function call and output lost their shared call_id"
	end
	if input[4].arguments ~= '{"command":"ls"}' then
		return false, "tool arguments did not encode as a JSON object string"
	end
	if toolArguments({}) ~= "{}" then
		return false, "an empty tool input did not encode as an object"
	end

	local tools = toResponseTools({
		{ name = "bash", description = "run", input_schema = { type = "object" },
			eager_input_streaming = true },
	}, 2)
	if not tools or tools[1].type ~= "function" or tools[1].parameters == nil
		or tools[1].strict ~= false
		or (tools[1] :: any).eager_input_streaming ~= nil
		or tools[2].type ~= "web_search" then
		return false, "tool definitions did not convert to Responses format"
	end

	local output = {
		rawReasoning,
		{ type = "message", id = "msg_1", content = {
			{ type = "output_text", text = "done", annotations = {} },
		} },
		{ type = "function_call", id = "fc_1", call_id = "call_2", name = "bash",
			arguments = '{"command":"pwd"}' },
		{ type = "web_search_call", id = "ws_1", status = "completed" },
	}
	local blocks, hasFunction = assemble(output, "", "gpt-6-astra")
	if not hasFunction or blocks[1].type ~= "thinking" or blocks[2].text ~= "done"
		or blocks[3].id ~= "call_2" or not blocks[3].inputParsed
		or blocks[4].type ~= "server_tool_use" or not blocks[5].raw._openai_item then
		return false, "Responses output items did not rebuild the internal block sequence"
	end
	local rebuiltReasoning = reasoningItem(blocks[1].signature, "gpt-6-astra")
	if not rebuiltReasoning or rebuiltReasoning.encrypted_content ~= "opaque" then
		return false, "an assembled reasoning item did not round-trip through its signature"
	end
	local exactReplay = toResponseInput({ { role = "assistant", content = blocks } }, "gpt-6-astra")
	if #exactReplay ~= #output or exactReplay[2].id ~= "msg_1"
		or exactReplay[3].id ~= "fc_1" then
		return false, "the complete Responses output sequence did not survive history"
	end
	local functionOnly = {
		{ type = "function_call", id = "fc_only", call_id = "call_only", name = "bash",
			arguments = '{"command":"ls"}', status = "completed" },
	}
	local functionBlocks = assemble(functionOnly, "", "gpt-6-astra")
	local functionReplay = toResponseInput({ { role = "assistant", content = functionBlocks } },
		"gpt-6-astra")
	if #functionReplay ~= 1 or functionReplay[1].id ~= "fc_only"
		or functionReplay[1].status ~= "completed" then
		return false, "a function-only response lost its exact ResponseItem"
	end
	local restoredConversation = HttpService:JSONDecode(HttpService:JSONEncode({
		{ role = "assistant", content = functionBlocks },
		{ role = "user", content = {
			{ type = "tool_result", tool_use_id = "call_only", content = "workspace listing" },
		} },
	}))
	local restoredReplay = toResponseInput(restoredConversation, "gpt-6-astra")
	if #restoredReplay ~= 2 or restoredReplay[1].id ~= "fc_only"
		or restoredReplay[2].type ~= "function_call_output"
		or restoredReplay[2].call_id ~= "call_only"
		or restoredReplay[2].output ~= "workspace listing" then
		return false, "a saved OpenAI tool call/result did not survive session restore"
	end
	local streamedOnly = completedOutput({ output = {} }, functionOnly)
	if #streamedOnly ~= 1 or streamedOnly[1].call_id ~= "call_only" then
		return false, "an empty completed output discarded streamed function calls"
	end
	local finalWins = completedOutput({ output = { { type = "message", id = "final" } } },
		{ { type = "message", id = "streamed" } })
	if #finalWins ~= 1 or finalWins[1].id ~= "final" then
		return false, "a complete final output was not authoritative"
	end
	local filledFinal = completedOutput({ output = {
		{ type = "function_call", id = "fc", call_id = "call", name = "bash", arguments = "" },
	} }, { { type = "function_call", id = "fc", call_id = "call", name = "bash",
		arguments = '{"command":"pwd"}' } })
	if filledFinal[1].arguments ~= '{"command":"pwd"}' then
		return false, "streamed function arguments did not fill an incomplete final item"
	end
	local crossModel = toResponseInput({ { role = "assistant", content = blocks } }, "gpt-5.6-sol")
	if #crossModel ~= 3 or crossModel[1].role ~= "assistant"
		or crossModel[2].type ~= "function_call" or crossModel[3].type ~= "web_search_call" then
		return false, "model switching did not discard model-bound encrypted reasoning"
	end
	local replay = toResponseInput({ { role = "assistant", content = {
		blocks[4], blocks[5].raw,
	} } }, "gpt-6-astra")
	if #replay ~= 1 or replay[1].type ~= "web_search_call" or replay[1].id ~= "ws_1" then
		return false, "a hosted web-search item did not survive internal history"
	end

	local usage = rebaseUsage({
		input_tokens = 100,
		input_tokens_details = { cached_tokens = 40, cache_write_tokens = 10 },
		output_tokens = 20,
	})
	if not usage or usage.input_tokens ~= 50 or usage.cache_read_input_tokens ~= 40
		or usage.cache_creation_input_tokens ~= 10 or usage.output_tokens ~= 20 then
		return false, "Responses usage was not rebased to Agent's cache accounting"
	end
	if not acceptsModelId("gpt-6-astra") or not acceptsModelId("o3")
		or acceptsModelId("text-embedding-3-large") then
		return false, "acceptsModelId accepted or rejected the wrong id"
	end
	if failureStatus({ code = "rate_limit_exceeded" }) ~= 429
		or failureStatus({ code = "server_is_overloaded" }) ~= 503
		or failureStatus({ code = "slow_down" }) ~= 503
		or failureStatus({ code = "insufficient_quota" }) ~= nil then
		return false, "Responses stream errors did not map to the right retry policy"
	end
	if responseStopReason({ end_turn = false }, false, nil) ~= "continue_turn"
		or responseStopReason({ end_turn = true }, false, nil) ~= "end_turn"
		or responseStopReason({ end_turn = true }, true, nil) ~= "tool_use"
		or responseStopReason({ end_turn = false }, false, "max_tokens") ~= "max_tokens" then
		return false, "Codex end_turn did not map to the right agent continuation"
	end
	if RESPONSES_URL ~= "https://chatgpt.com/backend-api/codex/responses"
		or RESPONSES_URL:find("api.openai.com", 1, true) then
		return false, "OpenAI provider is not pinned to the subscription-backed Codex endpoint"
	end
	return true
end

OpenAI.Initialize = Initialize
OpenAI.streamMessage = streamMessage
OpenAI.acceptsModelId = acceptsModelId
OpenAI.selfTest = selfTest
OpenAI._RESPONSES_URL = RESPONSES_URL

return OpenAI
