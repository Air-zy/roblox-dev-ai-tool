--!strict
-- ToolJson.luau: decoding the tool arguments a model wrote, and the two
-- conversions every non-Anthropic wire needs on the way back out.

local HttpService = game:GetService("HttpService")

local ToolJson = {}

-- Models sometimes write a LITERAL newline inside a JSON string instead of `\n`,
-- and JSONDecode refuses the whole call over it. RFC 8259 forbids an unescaped
-- control character there, so escaping it has one possible reading. Only inside
-- strings, and only after the strict parse fails: a truncated call still fails.
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

-- The arguments or nil, and whether the repair was needed (the caller warns).
function ToolJson.decode(json: string): (any?, boolean)
	local parsed
	-- A no-arg call streams no fragments, and JSONDecode("") throws.
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

-- A tool_use input as a JSON object string. `{}` would encode as `[]`.
function ToolJson.encode(input: any): string
	if type(input) ~= "table" or next(input) == nil then return "{}" end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(input) end)
	return if ok then encoded else "{}"
end

-- A tool_result's content as one string; a restored session may hold blocks.
function ToolJson.resultText(content: any): string
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

-- Self-test
function ToolJson.selfTest(): (boolean, string?)
	local good = ToolJson.decode('{"path":"/a","content":"one\\ntwo"}')
	if not good or good.content ~= "one\ntwo" then
		return false, "a valid tool input did not decode"
	end
	-- The newline between values is legal and must survive untouched.
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
