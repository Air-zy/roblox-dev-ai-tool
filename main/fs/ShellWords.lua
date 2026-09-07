--!optimize 2
-- Expansion happens on parsed words, immediately before execution. Values never
-- go back through the lexer, so a filename containing ';' cannot become code.
local Syntax = require(script.Parent:WaitForChild("ShellSyntax"))
local Words = {}
local MAX_WORDS, MAX_BYTES = 10000, 1000000
local function bad(message: string): never error(message, 0) end

-- Integer arithmetic, parsed rather than executed as Luau. Shell arithmetic has
-- its own precedence, integer division, and short circuit operators.
function Words.arithmetic(source: string, variables: { [string]: string }, nesting: number?): number
	local depth = nesting or 0
	if depth > 32 or #source > 10000 then bad("arithmetic expression is too large or recursive") end
	local tokens, i = {}, 1
	while i <= #source do
		local tail = source:sub(i)
		local space = tail:match("^%s+")
		if space then i += #space; continue end
		-- Longest first, always: `++` before `+`, `<<=` before `<<` before `<`,
		-- `**=` before `**`. Reversing any pair silently changes the expression.
		local token = tail:match("^0[xX][%da-fA-F]+") or tail:match("^%d+")
			or tail:match("^[%a_][%w_]*")
			or tail:match("^(<<=)") or tail:match("^(>>=)") or tail:match("^(%*%*=)")
			or tail:match("^(%+%+)") or tail:match("^(%-%-)")
			or tail:match("^([%+%-%*/%%&|^]=)")
			or tail:match("^([<>=!]=)")
			or tail:match("^([<>][<>])") or tail:match("^(&&)") or tail:match("^(||)")
			or tail:match("^(%*%*)") or tail:match("^([()+*/%%<>&|^!~?:%-=])")
		if not token then bad("unsupported arithmetic near " .. tail:sub(1, 20)) end
		tokens[#tokens + 1] = token; i += #token
	end
	local precedence = { ["||"] = 1, ["&&"] = 2, ["|"] = 3, ["^"] = 4, ["&"] = 5,
		["=="] = 6, ["!="] = 6, ["<"] = 7, ["<="] = 7, [">"] = 7, [">="] = 7,
		["<<"] = 8, [">>"] = 8, ["+"] = 9, ["-"] = 9,
		["*"] = 10, ["/"] = 10, ["%"] = 10, ["**"] = 11 }
	local ASSIGN = { ["="] = true, ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true,
		["%="] = true, ["<<="] = true, [">>="] = true, ["&="] = true, ["|="] = true,
		["^="] = true, ["**="] = true }
	local at, parse = 1, nil
	local function name(node: any, what: string): string
		if not node or not node.value or not node.value:match("^[%a_][%w_]*$") then
			bad("arithmetic: " .. what .. " needs a variable")
		end
		return node.value
	end
	function parse(minimum: number, level: number): any
		if level > 64 then bad("arithmetic nested more than 64 deep") end
		local token = tokens[at]; at += 1
		local left
		if token == "(" then
			left = parse(0, level + 1)
			if tokens[at] ~= ")" then bad("arithmetic: missing )") end
			at += 1
		elseif token == "++" or token == "--" then
			-- Pre-increment yields the NEW value. Read as two unary signs this was
			-- the old value, unchanged, with no error to say so.
			left = { step = token, pre = true, name = name(parse(12, level + 1), token) }
		elseif token == "+" or token == "-" or token == "!" or token == "~" then
			left = { unary = token, rhs = parse(12, level + 1) }
		elseif token and token:match("^[%w_]+$") then left = { value = token }
		else bad("arithmetic: expected a number or variable") end
		-- Post-increment yields the old value and binds tighter than any operator.
		while tokens[at] == "++" or tokens[at] == "--" do
			left = { step = tokens[at], pre = false, name = name(left, tokens[at]) }; at += 1
		end
		-- Assignment is right-associative and lower than everything but `?:`.
		if minimum == 0 and tokens[at] and ASSIGN[tokens[at]] then
			local op = tokens[at]; at += 1
			return { assign = op, name = name(left, op), rhs = parse(0, level + 1) }
		end
		while tokens[at] do
			local op = tokens[at]
			local priority = precedence[op]
			if not priority or priority < minimum then break end
			at += 1
			left = { op = op, lhs = left, rhs = parse(op == "**" and priority or priority + 1, level + 1) }
		end
		if minimum == 0 and tokens[at] == "?" then
			at += 1; local yes = parse(0, level + 1)
			if tokens[at] ~= ":" then bad("arithmetic: expected :") end
			at += 1; left = { condition = left, yes = yes, no = parse(0, level + 1) }
		end
		return left
	end
	if #tokens == 0 then return 0 end
	local root = parse(0, 0)
	if tokens[at] then bad("unsupported arithmetic operator " .. tokens[at]) end
	local function integer(value: number): number
		if value ~= value or math.abs(value) > 9007199254740991 or value % 1 ~= 0 then
			bad("arithmetic result exceeds the exact integer range")
		end
		return value
	end
	-- Luau's bit32 operates on unsigned 32-bit values. Split safe integers into
	-- signed high / unsigned low limbs instead, so ~0 and negative shifts retain
	-- shell semantics. Results outside our documented exact range are errors.
	local function bitwise(fn: any, a: number, b: number): number
		local high = fn(math.floor(a / 4294967296), math.floor(b / 4294967296))
		if high >= 2147483648 then high -= 4294967296 end
		return integer(high * 4294967296 + fn(a % 4294967296, b % 4294967296))
	end
	local function eval(node: any): number
		if node.step then
			local before = Words.arithmetic(variables[node.name] or "0", variables, depth + 1)
			local after = integer(node.step == "++" and before + 1 or before - 1)
			variables[node.name] = tostring(after)
			return node.pre and after or before
		end
		if node.assign then
			local value = eval(node.rhs)
			if node.assign ~= "=" then
				local current = Words.arithmetic(variables[node.name] or "0", variables, depth + 1)
				value = eval({ op = node.assign:sub(1, -2), lhs = { literal = current }, rhs = { literal = value } })
			end
			variables[node.name] = tostring(value)
			return value
		end
		if node.literal then return node.literal end
		if node.value then
			local value = node.value
			if value:match("^[%a_]") then return Words.arithmetic(variables[value] or "0", variables, depth + 1) end
			local n = value:match("^0[0-9]+$") and tonumber(value, 8) or tonumber(value)
			if value:match("^0[0-9]+$") and value:find("[89]") then bad("invalid octal number " .. value) end
			if not n then bad("invalid number " .. value) end
			return integer(n)
		end
		if node.condition then return eval(eval(node.condition) ~= 0 and node.yes or node.no) end
		if node.unary then
			local rhs = eval(node.rhs)
			if node.unary == "+" then return rhs elseif node.unary == "-" then return -rhs
			elseif node.unary == "!" then return rhs == 0 and 1 or 0 else return integer(-rhs - 1) end
		end
		local a, op = eval(node.lhs), node.op
		if op == "&&" and a == 0 then return 0 end
		if op == "||" and a ~= 0 then return 1 end
		local b = eval(node.rhs)
		if op == "&&" or op == "||" then return b ~= 0 and 1 or 0 end
		if op == "==" then return a == b and 1 or 0 elseif op == "!=" then return a ~= b and 1 or 0
		elseif op == "<" then return a < b and 1 or 0 elseif op == "<=" then return a <= b and 1 or 0
		elseif op == ">" then return a > b and 1 or 0 elseif op == ">=" then return a >= b and 1 or 0 end
		if op == "+" then return integer(a + b) elseif op == "-" then return integer(a - b)
		elseif op == "*" then return integer(a * b) elseif op == "**" then return integer(a ^ b)
		elseif op == "/" or op == "%" then
			if b == 0 then bad("arithmetic: division by zero") end
			local quotient = a / b; quotient = quotient < 0 and math.ceil(quotient) or math.floor(quotient)
			return integer(op == "/" and quotient or a - quotient * b)
		elseif op == "&" then return bitwise(bit32.band, a, b) elseif op == "|" then return bitwise(bit32.bor, a, b)
		elseif op == "^" then return bitwise(bit32.bxor, a, b)
		else
			if b < 0 or b > 52 then bad("arithmetic shift count must be between 0 and 52") end
			return integer(op == "<<" and a * 2 ^ b or math.floor(a / 2 ^ b))
		end
	end
	return eval(root)
end

local function quotedChar(char: string): string
	return char:find("[\\*?%[%]]") and ("\\" .. char) or char
end

-- Glob matcher shared by pathname expansion and case. Backslash records quote
-- protection; bracket classes/ranges have shell spelling, not regex spelling.
function Words.matches(pattern: string, text: string): boolean
	if (#pattern + 1) * (#text + 1) > 1000000 then bad("glob match exceeds 1000000 steps") end
	local tokens, i = {}, 1
	local function character(at: number): (string, number)
		if pattern:sub(at, at) == "\\" and at < #pattern then return pattern:sub(at + 1, at + 1), at + 2 end
		return pattern:sub(at, at), at + 1
	end
	while i <= #pattern do
		local c = pattern:sub(i, i)
		if c == "\\" then
			local value, after = character(i); tokens[#tokens + 1] = { literal = value }; i = after
		elseif c == "*" or c == "?" then
			if c ~= "*" or not tokens[#tokens] or not tokens[#tokens].star then
				tokens[#tokens + 1] = c == "*" and { star = true } or { any = true }
			end
			i += 1
		elseif c == "[" then
			local at, negate, members, count = i + 1, false, {}, 0
			if pattern:sub(at, at) == "!" or pattern:sub(at, at) == "^" then negate = true; at += 1 end
			while at <= #pattern and (pattern:sub(at, at) ~= "]" or count == 0) do
				local first, after = character(at)
				if pattern:sub(after, after) == "-" and after + 1 <= #pattern and pattern:sub(after + 1, after + 1) ~= "]" then
					local last, finish = character(after + 1)
					for byte = first:byte(), last:byte() do members[string.char(byte)] = true end
					at = finish
				else members[first] = true; at = after end
				count += 1
			end
			if pattern:sub(at, at) == "]" then
				tokens[#tokens + 1] = { members = members, negate = negate }; i = at + 1
			else tokens[#tokens + 1] = { literal = "[" }; i += 1 end
		else tokens[#tokens + 1] = { literal = c }; i += 1 end
	end
	-- Dynamic programming bounds work to pattern x text, avoiding exponential
	-- backtracking on inputs such as *a*a*a*a*a* followed by a failing suffix.
	local previous = { [0] = true }
	for _, token in ipairs(tokens) do
		local current = { [0] = token.star and previous[0] or false }
		for at = 1, #text do
			local c = text:sub(at, at)
			if token.star then current[at] = previous[at] or current[at - 1]
			else
				local matches = token.any or token.literal == c
					or (token.members ~= nil and (token.members[c] == true) ~= token.negate)
				current[at] = previous[at - 1] and matches
			end
		end
		previous = current
	end
	return previous[#text] == true
end

-- Braces are expanded before parameters. Quoted braces, ${...}, and braces in
-- command substitutions are skipped, so expansion cannot come from a value.
local function braces(raw: string, depth: number): { string }
	if depth > 32 then bad("brace expansion nested more than 32 deep") end
	local open, level, commas, quote, i = nil, 0, {}, nil, 1
	while i <= #raw do
		local c = raw:sub(i, i)
		if c == "\\" then i += 2; continue end
		if quote then if c == quote then quote = nil end
		elseif c == "'" or c == '"' then quote = c
		elseif raw:sub(i, i + 1) == "$(" then i = Syntax.substitutionEnd(raw, i + 2, ")", 1); continue
		elseif raw:sub(i, i + 1) == "${" then i = Syntax.substitutionEnd(raw, i + 2, "}", 1); continue
		elseif c == "`" then i = Syntax.substitutionEnd(raw, i + 1, "`", 1); continue
		elseif c == "{" then level += 1; if level == 1 then open = i; commas = {} end
		elseif c == "," and level == 1 then commas[#commas + 1] = i
		elseif c == "}" and level > 0 then
			level -= 1
			if level == 0 then
				local choices = {}
				if #commas > 0 then
					local at = open + 1
					for _, comma in ipairs(commas) do choices[#choices + 1] = raw:sub(at, comma - 1); at = comma + 1 end
					choices[#choices + 1] = raw:sub(at, i - 1)
				else
					local body = raw:sub(open + 1, i - 1)
					local first, last, step = body:match("^([%-]?%d+)%.%.([%-]?%d+)%.%.([%-]?%d+)$")
					if not first then first, last = body:match("^([%-]?%d+)%.%.([%-]?%d+)$") end
					local letters = false
					if not first then first, last = body:match("^(%a)%.%.(%a)$"); letters = first ~= nil end
					if first then
						local a, b = letters and first:byte() or tonumber(first), letters and last:byte() or tonumber(last)
						local increment = math.abs(tonumber(step) or 1)
						if math.abs(a) > 9007199254740991 or math.abs(b) > 9007199254740991 or increment > 9007199254740991 then
							bad("brace range exceeds the exact integer range")
						end
						if increment == 0 then increment = 1 end
						if a > b then increment = -increment end
						if math.floor(math.abs((b - a) / increment)) + 1 > MAX_WORDS then bad("brace expansion exceeds 10000 words") end
						local width = (first:match("^%-?0%d") or last:match("^%-?0%d")) and math.max(#first, #last) or 0
						for n = a, b, increment do choices[#choices + 1] = letters and string.char(n) or string.format("%0" .. width .. "d", n) end
					end
				end
				if #choices > 0 then
					local out = {}
					for _, choice in ipairs(choices) do
						for _, result in ipairs(braces(raw:sub(1, open - 1) .. choice .. raw:sub(i + 1), depth + 1)) do
							out[#out + 1] = result
							if #out > MAX_WORDS then bad("brace expansion exceeds 10000 words") end
						end
					end
					return out
				end
			end
		end
		i += 1
	end
	return { raw }
end

local function paths(field: any, context: any): { string }
	if not field.magic then return { field.text } end
	local absolute = field.text:sub(1, 1) == "/"
	local current = { absolute and "/" or "" }
	for segment in field.pattern:gmatch("[^/]+") do
		local nextPaths = {}
		for _, parent in ipairs(current) do
			local prefix = parent == "" and "" or parent == "/" and "/" or parent .. "/"
			if not segment:find("[*?%[]") then
				nextPaths[#nextPaths + 1] = prefix .. segment:gsub("\\(.)", "%1")
			else
				for _, name in ipairs(context.list(parent == "" and "." or parent)) do
					if (name:sub(1, 1) ~= "." or segment:sub(1, 1) == ".") and Words.matches(segment, name) then
						nextPaths[#nextPaths + 1] = prefix .. name
					end
				end
			end
			if #nextPaths > MAX_WORDS then bad("pathname expansion exceeds 10000 words") end
		end
		current = nextPaths
	end
	local result = {}
	for _, path in ipairs(current) do
		if context.exists(path) then result[#result + 1] = path .. (field.text:sub(-1) == "/" and "/" or "") end
	end
	if #result == 0 then return { field.text } end -- bash's default nullglob=off
	table.sort(result)
	return result
end

-- context supplies variables, positional parameters, status, command capture,
-- and directory reads; there is no dependency here on Instances or handlers.
function Words.expand(raw: string, context: any, mode: string?, nesting: number?): { string }
	local depth = nesting or 0
	if depth > 32 then bad("parameter expansion nested more than 32 deep") end
	local split = mode == nil
	local variants = split and braces(raw, 0) or { raw }
	local result = {}
	for _, variant in ipairs(variants) do
		local function emptyField() return { parts = {}, patterns = {}, bytes = 0, magic = false, keep = false } end
		local fields, field, quote, i = {}, emptyField(), nil, 1
		local function flush(force: boolean?)
			if field.keep or field.bytes > 0 or force then
				field.text, field.pattern = table.concat(field.parts), table.concat(field.patterns)
				field.parts, field.patterns = nil, nil
				fields[#fields + 1] = field
			end
			field = emptyField()
		end
		local function append(text: string, protected: boolean, splitting: boolean?)
			if #text > MAX_BYTES then bad("expansion exceeds 1000000 bytes") end
			local ifs = context.vars.IFS
			if ifs == nil then ifs = " \t\n" end
			for c in text:gmatch(".") do
				if split and splitting and not protected and ifs:find(c, 1, true) then
					flush(not c:match("[ \t\n]"))
				else
					field.bytes += 1
					if field.bytes > MAX_BYTES then bad("expansion exceeds 1000000 bytes") end
					field.parts[#field.parts + 1] = c
					field.patterns[#field.patterns + 1] = protected and quotedChar(c) or c == "\\" and "\\\\" or c
					field.magic = field.magic or (not protected and c:find("[*?%[]") ~= nil)
				end
			end
		end
		local function parameter(name: string): string?
			if name == "?" then return tostring(context.status()) end
			if name == "#" then return tostring(#context.args) end
			if name == "0" then return "bash" end
			if name:match("^%d+$") then return context.args[tonumber(name)] end
			if name == "@" or name == "*" then return table.concat(context.args, (context.vars.IFS or " "):sub(1, 1)) end
			return context.vars[name]
		end
		while i <= #variant do
			local c = variant:sub(i, i)
			local protected = quote ~= nil or mode == "assignment" or mode == "heredoc"
			if c == "\\" and quote ~= "'" then
				local after = variant:sub(i + 1, i + 1)
				if mode == "heredoc" and not (after == "\\" or after == "$" or after == "`" or after == "\n") then
					append(c, true); i += 1
				elseif quote == nil or after:find('[\\$`"]') or after == "\n" then
					if after ~= "\n" then append(after, true); field.keep = true end
					i += 2
				else append(c, protected); i += 1 end
			elseif mode ~= "heredoc" and c == quote then quote = nil; i += 1
			elseif mode ~= "heredoc" and not quote and (c == "'" or c == '"') then quote = c; field.keep = true; i += 1
			elseif quote ~= "'" and variant:sub(i, i + 2) == "$((" then
				local after = Syntax.substitutionEnd(variant, i + 2, ")", 1)
				if variant:sub(after - 2, after - 1) ~= "))" then bad("arithmetic: missing ))") end
				local expression = table.concat(Words.expand(variant:sub(i + 3, after - 3), context, "assignment", depth + 1))
				append(tostring(Words.arithmetic(expression, context.vars)), protected, true); i = after
			elseif quote ~= "'" and (variant:sub(i, i + 1) == "$(" or c == "`") then
				local backtick = c == "`"
				local after = Syntax.substitutionEnd(variant, i + (backtick and 1 or 2), backtick and "`" or ")", 1)
				local inner = variant:sub(i + (backtick and 1 or 2), after - 2)
				if backtick then inner = inner:gsub("\\([\\$`])", "%1") end
				local output = context.capture(inner)
				append(output:gsub("\n+$", ""), protected, true); i = after
			elseif quote ~= "'" and c == "$" then
				local name, after, value
				if variant:sub(i + 1, i + 1) == "{" then
					after = Syntax.substitutionEnd(variant, i + 2, "}", 1)
					local expression = variant:sub(i + 2, after - 2)
					if expression:match("^#[%a_][%w_]*$") then value = tostring(#(parameter(expression:sub(2)) or ""))
					else
						name = expression:match("^([%a_][%w_]*)") or expression:match("^(%d+)") or expression:match("^([?@*#])")
						if not name then bad("bad substitution: ${" .. expression .. "}") end
						value = parameter(name)
						local tail = expression:sub(#name + 1)
						if tail ~= "" then
							local op, operand = tail:match("^(:?[%-%+%=%?])(.*)$")
							if not op then bad("unsupported parameter expansion: ${" .. expression .. "}") end
							local absent = value == nil or (op:sub(1, 1) == ":" and value == "")
							local action = op:sub(-1)
							if (action == "+" and not absent) or (action ~= "+" and absent) then
								value = table.concat(Words.expand(operand, context, "assignment", depth + 1))
								if action == "?" then bad(value ~= "" and value or name .. " is unset") end
								if action == "=" then
									if not name:match("^[%a_][%w_]*$") then bad("cannot assign to " .. name) end
									context.vars[name] = value
								end
							elseif action == "+" then value = "" end
						end
					end
				else
					name = variant:sub(i + 1):match("^([%a_][%w_]*)") or variant:sub(i + 1):match("^([%d?@*#])")
					if name then value = parameter(name); after = i + #name + 1 end
				end
				if after then
					if name == "@" and quote == '"' and split then
						for index, arg in ipairs(context.args) do
							if index > 1 then flush(true) end
							append(arg, true); field.keep = true
						end
						if #context.args == 0 and variant == '"$@"' then field.keep = false end
					else append(value or "", protected, true) end
					i = after
				else append(c, protected); i += 1 end
			elseif c == "~" and (i == 1 or (mode == "assignment"
				and variant:sub(i - 1, i - 1):find("[:=]") ~= nil))
				and (variant:sub(i + 1, i + 1) == "/" or i == #variant
					or (mode == "assignment" and variant:sub(i + 1, i + 1) == ":")) then
				-- bash expands a tilde at the start of an assignment's value AND after
				-- each unquoted colon in it, which is what makes PATH-shaped values
				-- work. Only position 1 of the whole word expanded here, so `A=~/x`
				-- did and `export B=~/x`, `local C=~/x` and `D=x:~/z` did not -- three
				-- spellings of one thing disagreeing.
				append(context.vars.HOME or "~", true); i += 1
			else append(c, protected); i += 1 end
		end
		flush(not split)
		for _, part in ipairs(fields) do
			if mode == "pattern" then result[#result + 1] = part.pattern
			elseif split then for _, path in ipairs(paths(part, context)) do result[#result + 1] = path end
			else result[#result + 1] = part.text end
			if #result > MAX_WORDS then bad("expansion exceeds 10000 words") end
		end
	end
	return result
end

return Words
