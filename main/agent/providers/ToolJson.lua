--!strict
-- ToolJson.luau: decoding a tool call's arguments, which the model wrote.
--
-- Extracted from Anthropic.luau when OpenRouter arrived. The failure it repairs
-- is the model's, not the transport's, so it happens identically on any wire:
-- every JSON-tool provider hands over a string some language model generated a
-- token at a time, and each gets the same illegal byte in the same place.

local HttpService = game:GetService("HttpService")

local ToolJson = {}

-- A tool call's arguments, decoded, or nil if they never became valid JSON.
--
-- The strict decode is the answer on every ordinary call. The repair below it
-- exists because the model sometimes writes a LITERAL newline inside a JSON
-- string instead of `\n`, most often in a long `write`/`multiedit` body
-- carrying a block comment. The stop reason on those turns is a normal tool
-- call, not a truncation: nothing was cut off, the JSON is complete and
-- balanced and simply illegal, and JSONDecode refuses the whole thing over one
-- byte.
--
-- Escaping it is a reading, not a guess. RFC 8259 forbids an unescaped control
-- character inside a string, so one appearing there has exactly one possible
-- intent, and the repair only ever runs after the strict parse has already
-- failed. Everything outside a string is left exactly as it arrived, so a
-- genuinely truncated call still fails — which is what makes the "retry with a
-- smaller input" hint the agent prints in its place true.
local UNESCAPED: { [string]: string } = {
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
	["\b"] = "\\b", ["\f"] = "\\f",
}

local function escapeControlChars(json: string): string
	local out: { string } = {}
	local inString, escaped = false, false
	for i = 1, #json do
		local c = json:sub(i, i)
		if escaped then
			escaped = false
		elseif inString and c == "\\" then
			escaped = true
		elseif c == '"' then
			inString = not inString
		elseif inString and c:byte() < 32 then
			c = UNESCAPED[c] or string.format("\\u%04x", c:byte())
		end
		out[#out + 1] = c
	end
	return table.concat(out)
end

-- Returns the arguments and whether the repair was needed. The caller warns
-- rather than this function, so that a selfTest can exercise the repair without
-- printing a warning into every startup.
function ToolJson.decode(json: string): (any?, boolean)
	local parsed
	-- JSONDecode("") throws; a no-arg tool call never emits any argument
	-- fragments, so the accumulator stays "".
	if pcall(function()
		parsed = HttpService:JSONDecode(json ~= "" and json or "{}")
	end) then
		return parsed, false
	end
	if not pcall(function()
		parsed = HttpService:JSONDecode(escapeControlChars(json))
	end) then
		return nil, false
	end
	return parsed, true
end

-- Self-test
-- The strict path must stay strict, and the repair must only ever rescue an
-- unescaped control character INSIDE a string: a body that is genuinely
-- truncated has to keep failing, or the "retry with a smaller input" the agent
-- prints in its place becomes a lie.
function ToolJson.selfTest(): (boolean, string?)
	local good = ToolJson.decode('{"path":"/a","content":"one\\ntwo"}')
	if not good or good.content ~= "one\ntwo" then
		return false, "a valid tool input did not decode"
	end
	-- The reported failure: a literal newline where the model owed a \n. The one
	-- BETWEEN values is legal whitespace and must survive untouched, which is the
	-- half that says the repair tracks string boundaries rather than replacing
	-- every newline in the document.
	local repaired = ToolJson.decode('{"path":"/a",\n"content":"one\ntwo"}')
	if not repaired or repaired.content ~= "one\ntwo" then
		return false, "a literal newline inside a JSON string was not repaired"
	end
	if ToolJson.decode('{"path":"/a","content":"tail\\"}') ~= nil then
		return false, "an escaped quote was miscounted, so the repair closed a string early"
	end
	if ToolJson.decode('{"path":"/a","content":"cut off') ~= nil then
		return false, "a truncated tool input was accepted; the retry hint would be wrong"
	end
	if ToolJson.decode("") == nil then
		return false, "a no-argument tool call did not decode as an empty object"
	end
	return true
end

return ToolJson
