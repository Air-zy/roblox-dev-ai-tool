--!optimize 2
-- ChatCompletions.luau: the chat/completions wire shared by OpenRouter and
-- Nvidia. One request, SSE back, and the translation between the internal
-- Anthropic-shaped conversation and chat messages in both directions. Each
-- provider passes in its body, headers, reasoning field and error text.
--
--   internal                             wire
--   user content: [tool_result, ...]     N x {role="tool", tool_call_id}
--   assistant text block                 content: "string"
--   assistant thinking + signature       reasoning_details[] or reasoning
--   assistant tool_use block             tool_calls[{id, function{name,arguments}}]
--   tools[{name, input_schema}]          tools[{type="function", function{parameters}}]

local HttpService = game:GetService("HttpService")
local warn = warn

local Stream = require(script.Parent:WaitForChild("Stream"))
local ToolJson = require(script.Parent:WaitForChild("ToolJson"))

local ChatCompletions = {}

-- A thinking block's signature: reasoning_details if the model sent them, else text.
local function reasoningFrom(signature: string?): (any?, string?)
	if type(signature) ~= "string" or signature == "" then return nil, nil end
	local ok, env = pcall(function() return HttpService:JSONDecode(signature) end)
	if not ok or type(env) ~= "table" then return nil, nil end
	return (env :: any).d, (env :: any).t
end

-- Returns a NEW array; `messages` is the live history and must not be written to.
-- `replayReasoning` sends thinking back verbatim, which OpenRouter requires.
-- Without it thinking is dropped here: NVIDIA has no field to take it back.
function ChatCompletions.toMessages(system: string?, messages: { any }, replayReasoning: boolean?): { any }
	local out: { any } = {}

	if system and system ~= "" then
		out[#out + 1] = { role = "system", content = system }
	end

	for _, message in ipairs(messages) do
		local content = message.content

		if type(content) == "string" then
			out[#out + 1] = { role = message.role, content = content }

		elseif type(content) == "table" and message.role == "user" then
			-- One `tool` message per result, before any loose text so they stay
			-- adjacent to the calls above.
			local texts: { string } = {}
			for _, block in ipairs(content) do
				if block.type == "tool_result" then
					out[#out + 1] = {
						role = "tool",
						tool_call_id = block.tool_use_id,
						content = ToolJson.resultText(block.content),
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
						["function"] = { name = block.name, arguments = ToolJson.encode(block.input) },
					}
				elseif block.type == "thinking" and replayReasoning then
					local d, t = reasoningFrom(block.signature)
					if d then details = d elseif t then reasoningText = t end
				end
			end

			local assistant: { [string]: any } = { role = "assistant" }
			assistant.content = if #texts > 0 then table.concat(texts, "\n") else ""
			if #toolCalls > 0 then assistant.tool_calls = toolCalls end
			if details then
				assistant.reasoning_details = details
			elseif reasoningText then
				assistant.reasoning = reasoningText
			end
			out[#out + 1] = assistant
		end
	end

	return out
end

function ChatCompletions.toTools(tools: { any }?): { any }?
	if not tools or #tools == 0 then return nil end
	local out: { any } = {}
	for _, tool in ipairs(tools) do
		-- No name means another provider's server tool.
		if tool.name then
			out[#out + 1] = {
				type = "function",
				["function"] = {
					name = tool.name,
					description = tool.description,
					-- eager_input_streaming is Anthropic-only; arguments stream here anyway.
					parameters = tool.input_schema,
				},
			}
		end
	end
	return if #out > 0 then out else nil
end

-- prompt_tokens INCLUDES cache reads and writes; Anthropic's input_tokens does
-- not, and Agent sums all three. Passed through raw, cached tokens count twice.
function ChatCompletions.rebaseUsage(u: any): any?
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

-- Anthropic's names, which Agent's diagnostics print.
local FINISH = {
	tool_calls = "tool_use",
	stop = "end_turn",
	length = "max_tokens",
}

-- `body` builds the request minus `tools`, and runs only after args are checked.
export type Options = {
	name: string,
	auth: any,
	url: string,
	headers: { [string]: string }?,
	reasoningField: string,
	body: () -> { [string]: any },
	explain: ((number?, string?) -> string?)?,
}

-- Same signature and callbacks as Anthropic.streamMessage.
function ChatCompletions.stream(opts: Options, args: {
	messages: { any },
	tools: { any }?,
	}, callbacks: {
		onText: ((string) -> ())?,
		onThinking: ((string) -> ())?,
		onToolUseStart: ((string?, string) -> ())?,
		onToolInput: ((string?, string) -> ())?,
		onComplete: ((any) -> ())?,
		onError: ((string, string?) -> ())?,
		onRetry: ((string, number, number, number) -> ())?,
		onDiscard: (() -> ())?,  -- the attempt so far is void; it is being asked again
	}): Stream.Handle
	local function noopHandle()
		return { cancelled = true, cancel = function() end }
	end

	local Auth = opts.auth
	if not Auth then
		if callbacks.onError then callbacks.onError(opts.name .. " module not initialized.") end
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

	local bodyTable = opts.body()
	local tools = ChatCompletions.toTools(args.tools)
	if tools then
		bodyTable.tools = tools
		bodyTable.tool_choice = "auto"
	end
	local bodyStr = HttpService:JSONEncode(bodyTable)

	local headers: { [string]: string } = {
		["content-type"] = "application/json",
		["accept"] = "text/event-stream",
	}
	for name, value in pairs(opts.headers or {}) do headers[name] = value end

	-- Accumulators, rebuilt per attempt by `reset` below.
	local textAcc = ""
	local reasonAcc = ""
	local reasoningDetails: { any } = {}
	local toolAcc: { any } = {}
	local toolCount = 0
	local usage: any = nil
	local stopReason: string? = nil
	local completed = false

	local function assemble(): { any }
		local blocks: { any } = {}
		if reasonAcc ~= "" or #reasoningDetails > 0 then
			-- Agent drops a thinking block without a signature, so there always is
			-- one: whatever toMessages has to send back next turn.
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

	local function readToolCalls(calls: any, ctrl: Stream.Ctrl)
		for _, call in ipairs(calls) do
			-- `index` ties fragments together; id and name come on the first one.
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

			-- Announced as soon as the name is known, so a long `write` shows while
			-- its arguments are still streaming.
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
			-- SSE comments (": OPENROUTER PROCESSING") are keepalives.
			if line:sub(1, 1) ~= ":" then
				local data = line:match("^data:%s*(.+)$")
				if data == "[DONE]" then
					complete(ctrl)
					return
				elseif data then
					local parsed
					if not pcall(function() parsed = HttpService:JSONDecode(data) end) then
						return
					end
					local chunk = parsed :: any

					-- A mid-stream error arrives as a chunk, inside an HTTP 200.
					if chunk.error then
						local err = chunk.error
						ctrl.fail(nil, data, string.format("stream error — %s",
							tostring(err.message or err.type or "unknown")))
						return
					end

					if chunk.usage then usage = ChatCompletions.rebaseUsage(chunk.usage) or usage end

					-- The usage chunk can carry an empty choices array.
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
							local reasoning = delta[opts.reasoningField]
							if type(reasoning) == "string" and reasoning ~= "" then
								ctrl.emitted()
								reasonAcc ..= reasoning
								if callbacks.onThinking then callbacks.onThinking(reasoning) end
							end
							-- Verbatim and in order: they are replayed next turn.
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
			-- Per attempt, retries included: that is what a rate limit counts.
			if Auth.noteRequest then Auth.noteRequest() end
			local attemptHeaders = table.clone(headers)
			attemptHeaders["Authorization"] = "Bearer " .. (key :: string)
			return {
				url = opts.url,
				headers = attemptHeaders,
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

		-- A clean close with no [DONE] fires no error; deliver what arrived rather
		-- than spin until Stop. NVIDIA ends long tool calls this way.
		closed = function(ctrl: Stream.Ctrl)
			if stopReason or textAcc ~= "" or toolCount > 0 then
				complete(ctrl)
			end
		end,

		partial = function(): string?
			return if textAcc ~= "" then textAcc else nil
		end,

		explain = opts.explain,

		-- No refresh hook: neither provider's key refreshes.
	}, {
		onError = callbacks.onError,
		onRetry = callbacks.onRetry,
		onDiscard = callbacks.onDiscard,
	})
end

return ChatCompletions
