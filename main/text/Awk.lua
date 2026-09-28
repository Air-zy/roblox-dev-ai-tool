--!optimize 2
-- Awk.luau: the awk language. Lexer, parser, interpreter, fields and records.
--
-- Pure text, like Sed beside it: no DataModel and no terminal. HANDLERS.awk in
-- Shell reads the program and the files and hands over three callbacks, read,
-- write and breathe; everything about what awk MEANS is here.
--
-- The target is POSIX awk plus the extensions every awk in use agrees on
-- (`delete a`, `nextfile`, `length(arr)`, `**`, hex constants, a regex RS), and
-- gawk is the oracle wherever POSIX leaves a choice open: tests/awk-cases.mjs
-- runs every vector through a real gawk and compares bytes. The earlier answer
-- here was a refusal, and before that a column-cutter in its place; a partial
-- awk would be worse than either, because `awk '{print $2}'` working says
-- nothing about whether the next program parses the way awk does.
--
-- What is refused, by name: system(), `cmd | getline` and `print | cmd`. Each
-- runs a shell command, which needs the shell to run a nested line from inside
-- a handler; the refusal says how to write the same thing with a pipe instead.
--
-- Shape: source -> tokens -> AST -> tree-walking interpreter. Not compiled to
-- Luau source, because loadstring is not available to plugins, and awk text
-- spliced into generated code would be one escaping bug from running as code.
local Regex = require(script.Parent:WaitForChild("Regex"))

local Awk = {}

-- Limits
-- Luau cannot preempt a running chunk, and a tool call cannot be stopped from
-- the outside once it runs, so `BEGIN { while (1) ; }` would hold Studio for
-- good. The interpreter breathes (yields a frame) as it goes and gives up after
-- a time limit. Time, not a step count like the shell's: a step that prints
-- costs ten of one that does nothing, so any count is either too small for a
-- real program or a minute long for a runaway one. What a runaway costs is the
-- turn it holds, and that is measured in seconds.
local MAX_SECONDS = 20
local MAX_OUTPUT = 4000000
local MAX_DEPTH = 200
local MAX_FIELD = 100000

-- Lexing

local KEYWORDS: { [string]: boolean } = {
	BEGIN = true, END = true, ["function"] = true, ["if"] = true, ["else"] = true,
	["while"] = true, ["for"] = true, ["do"] = true, ["break"] = true, ["continue"] = true,
	next = true, nextfile = true, exit = true, ["return"] = true, delete = true, ["in"] = true,
	getline = true, print = true, printf = true,
}

-- name -> { fewest, most } arguments
local BUILTINS: { [string]: { number } } = {
	length = { 0, 1 }, substr = { 2, 3 }, index = { 2, 2 }, split = { 2, 3 }, sub = { 2, 3 },
	gsub = { 2, 3 }, match = { 2, 2 }, sprintf = { 1, math.huge }, sin = { 1, 1 },
	cos = { 1, 1 }, atan2 = { 2, 2 }, exp = { 1, 1 }, log = { 1, 1 }, sqrt = { 1, 1 },
	int = { 1, 1 }, rand = { 0, 0 }, srand = { 0, 1 }, tolower = { 1, 1 }, toupper = { 1, 1 },
	close = { 1, 1 }, fflush = { 0, 1 }, system = { 1, 1 },
}

-- gawk's own functions. Calling one is a user function that was never defined,
-- which is the error POSIX awk gives; naming where it comes from saves the turn
-- spent wondering whether the spelling was wrong.
local GAWK_ONLY: { [string]: boolean } = {
	gensub = true, strftime = true, systime = true, mktime = true, asort = true, asorti = true,
	strtonum = true, patsplit = true, isarray = true, typeof = true, ["and"] = true,
	["or"] = true, xor = true, lshift = true, rshift = true, compl = true,
}

-- Longest first, so `**=` is not read as `**` then `=`.
local OPERATORS = { "**=", "&&", "||", "==", "<=", ">=", "!=", "!~", "++", "--", "+=", "-=",
	"*=", "/=", "%=", "^=", "**", ">>" }
local SINGLE = "{}()[];,+-*/%^!><|?:~$="

-- After one of these a `/` divides; anywhere else it opens a regex. That is the
-- whole of awk's regex/division ambiguity, decided the way every awk decides it.
local DIVIDES: { [string]: boolean } = {
	name = true, num = true, str = true, ere = true, builtin = true,
	[")"] = true, ["]"] = true, ["++"] = true, ["--"] = true,
}

local ESCAPES: { [string]: string } = {
	['"'] = '"', ["\\"] = "\\", ["/"] = "/", a = "\a", b = "\b", f = "\f", n = "\n",
	r = "\r", t = "\t", v = "\v",
}

-- A string literal's escapes. -v values and command-line assignments go through
-- the same table, as they do in awk. An escape awk does not define keeps its
-- character and drops the backslash, with gawk's warning: `"\."` is ".", which
-- is a regex matching anything, and a model that meant a literal dot should
-- hear about it rather than get every line back.
local function unescape(raw: string, warnings: { string }?): string
	if not raw:find("\\", 1, true) then
		return raw
	end
	local out: { string } = {}
	local i = 1
	while true do
		local at = raw:find("\\", i, true)
		if not at then
			out[#out + 1] = raw:sub(i)
			break
		end
		out[#out + 1] = raw:sub(i, at - 1)
		local c = raw:sub(at + 1, at + 1)
		if ESCAPES[c] then
			out[#out + 1] = ESCAPES[c]
			i = at + 2
		elseif c:match("[0-7]") then
			local digits = raw:match("^[0-7][0-7]?[0-7]?", at + 1) :: string
			out[#out + 1] = string.char(tonumber(digits, 8) :: number % 256)
			i = at + 1 + #digits
		elseif c == "x" and raw:match("^%x", at + 2) then
			local digits = raw:match("^%x%x?", at + 2) :: string
			out[#out + 1] = string.char(tonumber(digits, 16) :: number)
			i = at + 2 + #digits
		elseif c == "\n" then
			i = at + 2
		elseif c == "" then
			out[#out + 1] = "\\"
			i = at + 1
		else
			if warnings then
				warnings[#warnings + 1] = string.format(
					"warning: escape sequence `\\%s' treated as plain `%s'", c, c)
			end
			out[#out + 1] = c
			i = at + 2
		end
	end
	return table.concat(out)
end

-- The body of /.../, from the opening slash. `\/` is a slash; every other
-- escape is the regex engine's. A slash inside a bracket expression does not
-- close it, which is gawk's reading and the one `/[/]/` needs.
local function scanRegex(src: string, start: number): (string?, number)
	local out: { string } = {}
	local j = start + 1
	local inBracket = false
	while true do
		local c = src:sub(j, j)
		if c == "" or c == "\n" then
			return nil, j
		end
		if c == "\\" then
			local d = src:sub(j + 1, j + 1)
			if d == "" or d == "\n" then
				return nil, j
			end
			out[#out + 1] = if d == "/" then "/" else c .. d
			j += 2
		elseif inBracket then
			local kind = src:sub(j + 1, j + 1)
			if c == "[" and (kind == ":" or kind == "." or kind == "=") then
				local close = src:find(kind .. "]", j + 2, true)
				local stop = close and close + 1 or j
				out[#out + 1] = src:sub(j, stop)
				j = stop + 1
			else
				if c == "]" then
					inBracket = false
				end
				out[#out + 1] = c
				j += 1
			end
		elseif c == "[" then
			inBracket = true
			out[#out + 1] = c
			j += 1
			if src:sub(j, j) == "^" then
				out[#out + 1] = "^"
				j += 1
			end
			if src:sub(j, j) == "]" then
				out[#out + 1] = "]"
				j += 1
			end
		elseif c == "/" then
			return table.concat(out), j + 1
		else
			out[#out + 1] = c
			j += 1
		end
	end
end

local function lex(src: string): ({ any }, { string })
	local toks: { any } = {}
	local warnings: { string } = {}
	local i, line, lineStart = 1, 1, 1
	local n = #src

	local function push(kind: string, value: any, start: number, stop: number)
		toks[#toks + 1] = { t = kind, v = value, line = line, col = start - lineStart + 1,
			text = src:sub(start, stop) }
	end
	local function fail(message: string, at: number)
		error({ syntax = message, tok = { line = line, col = at - lineStart + 1 } }, 0)
	end

	while i <= n do
		local c = src:sub(i, i)
		if c == " " or c == "\t" or c == "\r" then
			i += 1
		elseif c == "\n" then
			push("nl", nil, i, i)
			i += 1
			line += 1
			lineStart = i
		elseif c == "\\" and src:sub(i + 1, i + 1) == "\n" then
			i += 2
			line += 1
			lineStart = i
		elseif c == "\\" and src:sub(i + 1, i + 2) == "\r\n" then
			i += 3
			line += 1
			lineStart = i
		elseif c == "#" then
			i = src:find("\n", i, true) or n + 1
		elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
			-- Decimal as POSIX has it, so 010 is ten. Hex is gawk's and mawk's, and
			-- unambiguous: POSIX would read `0x1A` as 0 concatenated with a variable.
			local text = src:match("^0[xX]%x+", i)
			local value
			if text then
				value = tonumber(text)
			else
				text = src:match("^%d*%.?%d*", i) :: string
				local exponent = src:match("^[eE][+-]?%d+", i + #text)
				if exponent then
					text ..= exponent
				end
				value = tonumber(text)
			end
			push("num", value, i, i + #text - 1)
			i += #text
		elseif c:match("[%a_]") then
			local word = src:match("^[%a_][%w_]*", i) :: string
			local stop = i + #word - 1
			local kind = if word == "func" then "function" else word
			if KEYWORDS[kind] then
				push(kind, kind, i, stop)
			elseif BUILTINS[word] then
				push("builtin", word, i, stop)
			elseif src:sub(stop + 1, stop + 1) == "(" then
				-- A user function call has no space before its parenthesis; with one,
				-- `f (x)` is the variable f concatenated with (x).
				push("funcname", word, i, stop)
			else
				push("name", word, i, stop)
			end
			i = stop + 1
		elseif c == '"' then
			local j = i + 1
			local startLine, startCol = line, i - lineStart + 1
			while true do
				local d = src:sub(j, j)
				if d == "" or d == "\n" then
					fail("unterminated string", i)
				end
				if d == "\\" then
					if src:sub(j + 1, j + 1) == "\n" then
						line += 1
						lineStart = j + 2
					end
					j += 2
				elseif d == '"' then
					break
				else
					j += 1
				end
			end
			toks[#toks + 1] = { t = "str", v = unescape(src:sub(i + 1, j - 1), warnings),
				line = startLine, col = startCol, text = src:sub(i, j) }
			i = j + 1
		elseif c == "/" and not (toks[#toks] and DIVIDES[toks[#toks].t]) then
			local source, stop = scanRegex(src, i)
			if not source then
				fail("unterminated regex", i)
			end
			-- Compiled here, so a bad pattern is a syntax error before anything runs.
			local program, err = Regex.compile(source :: string, { ere = true })
			if not program then
				fail(string.format("invalid regex /%s/: %s", source :: string, tostring(err)), i)
			end
			push("ere", source, i, stop - 1)
			toks[#toks].prog = program
			i = stop
		else
			local op: string? = nil
			for _, candidate in ipairs(OPERATORS) do
				if src:sub(i, i + #candidate - 1) == candidate then
					op = candidate
					break
				end
			end
			if not op and SINGLE:find(c, 1, true) then
				op = c
			end
			if not op then
				fail(string.format("unexpected character `%s'", c), i)
			end
			local width = #(op :: string)
			local kind = if op == "**" then "^" elseif op == "**=" then "^=" else op :: string
			push(kind, nil, i, i + width - 1)
			i += width
		end
	end
	push("eof", nil, n + 1, n)
	return toks, warnings
end

-- Parsing

local LVALUE: { [string]: boolean } = { global = true, ["local"] = true, nf = true,
	field = true, index = true }
local function isLvalue(node: any): boolean
	return LVALUE[node.k] == true
end

local ASSIGN: { [string]: boolean } = { ["="] = true, ["+="] = true, ["-="] = true,
	["*="] = true, ["/="] = true, ["%="] = true, ["^="] = true }
local COMPARE: { [string]: boolean } = { ["<"] = true, ["<="] = true, ["=="] = true,
	["!="] = true, [">="] = true, [">"] = true }
-- Tokens that can start the right-hand side of a concatenation. `+` and `-` are
-- not among them: after an operand they are binary, so `1 " " -1` is 1 then
-- (" " - 1), printing `1-1`, which is what gawk prints.
local CONCAT_START: { [string]: boolean } = {
	num = true, str = true, ere = true, name = true, funcname = true, builtin = true,
	["$"] = true, ["("] = true, ["++"] = true, ["--"] = true,
}
local ENDS_STATEMENT: { [string]: boolean } = { [";"] = true, nl = true, ["}"] = true, eof = true }
local ENDS_PRINT: { [string]: boolean } = { [";"] = true, nl = true, ["}"] = true, eof = true,
	[">"] = true, [">>"] = true, ["|"] = true }

local PIPE_GETLINE = "`cmd | getline` runs a shell command, which this awk does not do; " ..
	"feed the output in instead: `cmd | awk '...'`, or `awk -v v=\"$(cmd)\" '...'`"
local PRINT_PIPE = "`print | cmd` pipes into a shell command, which this awk does not do; " ..
	"pipe awk's own output instead: `awk '...' | cmd`"
local SYSTEM = "system() runs a shell command, which this awk does not do; print the " ..
	"commands and run them from the shell, or run them after awk in the same line"

local RECORD = { k = "field", index = { k = "num", v = 0 } }

local function parse(src: string): (any, { string })
	local toks, warnings = lex(src)
	local p = 1
	-- True while parsing print's own argument list, where `>` is a redirection
	-- rather than a comparison. Anything in parentheses turns it back off.
	local noGt = false
	local loopDepth = 0
	local params: { [string]: number }? = nil
	local context = "main"
	local functions: { [string]: any } = {}
	local calls: { any } = {}

	-- Exit 1, as gawk exits on a syntax error. A refusal and a call to a
	-- function that does not exist pass 2, gawk's status for a fatal error.
	local function fail(message: string, at: any?, code: number?): never
		error({ syntax = message, tok = at or toks[p], code = code or 1 }, 0)
	end
	local function describe(tok: any): string
		if tok.t == "nl" then
			return "newline"
		elseif tok.t == "eof" then
			return "end of program"
		end
		return "`" .. tok.text .. "'"
	end
	local function advance(): any
		local tok = toks[p]
		if tok.t ~= "eof" then
			p += 1
		end
		return tok
	end
	local function kind(offset: number?): string
		local tok = toks[p + (offset or 0)]
		return if tok then tok.t else "eof"
	end
	local function expect(t: string): any
		if toks[p].t ~= t then
			fail(string.format("expected `%s', found %s", t, describe(toks[p])))
		end
		return advance()
	end
	local function skipNewlines()
		while toks[p].t == "nl" do
			p += 1
		end
	end

	local function varRef(name: string): any
		if params and params[name] then
			return { k = "local", slot = params[name], name = name }
		end
		if name == "NF" then
			return { k = "nf", name = name }
		end
		return { k = "global", name = name }
	end

	local expr, primary, unary, exprList

	local function arrayName(): any
		local tok = toks[p]
		if tok.t ~= "name" then
			fail("expected an array name, found " .. describe(tok))
		end
		advance()
		return varRef(tok.v)
	end

	local function callArgs(): { any }
		local saved = noGt
		noGt = false
		skipNewlines()
		local args = {}
		if toks[p].t ~= ")" then
			args = exprList()
		end
		skipNewlines()
		expect(")")
		noGt = saved
		return args
	end

	local function builtinCall(): any
		local tok = advance()
		local name = tok.v
		if name == "system" then
			fail(SYSTEM, tok, 2)
		end
		local args
		if toks[p].t == "(" then
			advance()
			args = callArgs()
		elseif name == "length" then
			args = {}
		else
			fail(name .. " needs its arguments in parentheses", tok)
		end
		local arity = BUILTINS[name]
		if #args < arity[1] or #args > arity[2] then
			fail(string.format("%s takes %s argument%s", name,
				if arity[1] == arity[2] then tostring(arity[1])
					elseif arity[2] == math.huge then "at least " .. arity[1]
					else arity[1] .. " or " .. arity[2],
				if arity[2] == 1 then "" else "s"), tok)
		end
		if name == "split" and args[2].k ~= "global" and args[2].k ~= "local" then
			fail("split's second argument must be an array name", tok)
		end
		return { k = "builtin", name = name, args = args }
	end

	-- `getline`, `getline var`, `getline < file`, `getline var < file`. The file
	-- is a primary, not a concatenation, so `getline < file > 0` compares.
	local function simpleGet(): any
		advance()
		local target
		if toks[p].t == "$" then
			advance()
			target = { k = "field", index = primary() }
		elseif toks[p].t == "name" then
			local name = advance().v
			if toks[p].t == "[" then
				advance()
				local saved = noGt
				noGt = false
				local subs = exprList()
				expect("]")
				noGt = saved
				target = { k = "index", array = varRef(name), subs = subs }
			else
				target = varRef(name)
			end
		end
		local file
		if toks[p].t == "<" then
			advance()
			file = primary()
		end
		return { k = "getline", target = target, file = file }
	end

	primary = function(): any
		local tok = toks[p]
		local k = tok.t
		if k == "num" then
			advance()
			return { k = "num", v = tok.v }
		elseif k == "str" then
			advance()
			return { k = "str", v = tok.v }
		elseif k == "ere" then
			advance()
			return { k = "regex", prog = tok.prog, src = tok.v }
		elseif k == "$" then
			-- `$` binds tighter than anything but grouping: `$i++` is ($i)++ and
			-- `$NF-1` is ($NF)-1.
			advance()
			return { k = "field", index = primary() }
		elseif k == "(" then
			advance()
			local grouping = noGt
			local saved = noGt
			noGt = false
			local first = expr()
			if toks[p].t == "," then
				local items = { first }
				while toks[p].t == "," do
					advance()
					skipNewlines()
					items[#items + 1] = expr()
				end
				expect(")")
				noGt = saved
				if toks[p].t == "in" then
					advance()
					return { k = "in", keys = items, array = arrayName() }
				end
				if not grouping then
					fail("a parenthesised list is only print's arguments, or the keys of an `in` test", tok)
				end
				return { k = "group", items = items }
			end
			expect(")")
			noGt = saved
			return first
		elseif k == "-" or k == "+" or k == "!" then
			advance()
			return { k = "unary", op = k, a = unary() }
		elseif k == "++" or k == "--" then
			advance()
			local target = primary()
			if not isLvalue(target) then
				fail(k .. " needs a variable, field or element", tok)
			end
			return { k = "incr", target = target, delta = if k == "++" then 1 else -1, post = false }
		elseif k == "name" then
			advance()
			if toks[p].t == "[" then
				advance()
				local saved = noGt
				noGt = false
				local subs = exprList()
				expect("]")
				noGt = saved
				return { k = "index", array = varRef(tok.v), subs = subs }
			end
			return varRef(tok.v)
		elseif k == "funcname" then
			advance()
			advance()
			local args = callArgs()
			calls[#calls + 1] = { name = tok.v, tok = tok, n = #args }
			return { k = "call", name = tok.v, args = args }
		elseif k == "builtin" then
			return builtinCall()
		elseif k == "getline" then
			return simpleGet()
		end
		fail("unexpected " .. describe(tok))
	end

	local function postfix(): any
		local base = primary()
		local k = toks[p].t
		if (k == "++" or k == "--") and isLvalue(base) then
			advance()
			return { k = "incr", target = base, delta = if k == "++" then 1 else -1, post = true }
		end
		return base
	end

	-- Right-associative, and the exponent may carry its own sign: 2^-1.
	local power
	local function exponent(): any
		local k = toks[p].t
		if k == "-" or k == "+" or k == "!" then
			advance()
			return { k = "unary", op = k, a = exponent() }
		end
		return power()
	end
	power = function(): any
		local base = postfix()
		if toks[p].t == "^" then
			advance()
			return { k = "binop", op = "^", a = base, b = exponent() }
		end
		return base
	end

	unary = function(): any
		local k = toks[p].t
		if k == "-" or k == "+" or k == "!" then
			advance()
			return { k = "unary", op = k, a = unary() }
		end
		return power()
	end

	local function multiplicative(): any
		local left = unary()
		while true do
			local k = toks[p].t
			if k ~= "*" and k ~= "/" and k ~= "%" then
				return left
			end
			advance()
			left = { k = "binop", op = k, a = left, b = unary() }
		end
	end

	local function additive(): any
		local left = multiplicative()
		while true do
			local k = toks[p].t
			if k ~= "+" and k ~= "-" then
				return left
			end
			advance()
			left = { k = "binop", op = k, a = left, b = multiplicative() }
		end
	end

	local function concat(): any
		local first = additive()
		if not CONCAT_START[toks[p].t] then
			return first
		end
		local items = { first }
		while CONCAT_START[toks[p].t] do
			items[#items + 1] = additive()
		end
		return { k = "concat", items = items }
	end

	-- Non-associative, as in awk's grammar: `1 < 2 < 3` is a syntax error.
	local function comparison(): any
		local left = concat()
		local k = toks[p].t
		if k == "|" and kind(1) == "getline" then
			fail(PIPE_GETLINE, nil, 2)
		end
		if not COMPARE[k] or (k == ">" and noGt) then
			return left
		end
		advance()
		left = { k = "cmp", op = k, a = left, b = concat() }
		k = toks[p].t
		if COMPARE[k] and not (k == ">" and noGt) then
			fail("unexpected " .. describe(toks[p]) .. "; comparisons do not chain, " ..
				"so parenthesise one of them")
		end
		if k == "|" and kind(1) == "getline" then
			fail(PIPE_GETLINE, nil, 2)
		end
		return left
	end

	local function matching(): any
		local left = comparison()
		while toks[p].t == "~" or toks[p].t == "!~" do
			local negate = advance().t == "!~"
			left = { k = "match", neg = negate, a = left, b = comparison() }
		end
		return left
	end

	local function membership(): any
		local left = matching()
		while toks[p].t == "in" do
			advance()
			left = { k = "in", keys = { left }, array = arrayName() }
		end
		return left
	end

	local function conjunction(): any
		local left = membership()
		while toks[p].t == "&&" do
			advance()
			skipNewlines()
			left = { k = "and", a = left, b = membership() }
		end
		return left
	end

	local function disjunction(): any
		local left = conjunction()
		while toks[p].t == "||" do
			advance()
			skipNewlines()
			left = { k = "or", a = left, b = conjunction() }
		end
		return left
	end

	expr = function(): any
		local left = disjunction()
		local k = toks[p].t
		if k == "?" then
			advance()
			skipNewlines()
			local a = expr()
			skipNewlines()
			expect(":")
			skipNewlines()
			return { k = "cond", c = left, a = a, b = expr() }
		end
		if ASSIGN[k] then
			if not isLvalue(left) then
				fail("can only assign to a variable, field or element")
			end
			advance()
			skipNewlines()
			return { k = "assign", op = k, target = left, value = expr() }
		end
		return left
	end

	exprList = function(): { any }
		local list = { expr() }
		while toks[p].t == "," do
			advance()
			skipNewlines()
			list[#list + 1] = expr()
		end
		return list
	end

	local statement, block

	local function terminator()
		local k = toks[p].t
		if k == ";" or k == "nl" then
			advance()
		elseif k ~= "}" and k ~= "eof" then
			fail("unexpected " .. describe(toks[p]) .. "; end the statement with ; or a newline")
		end
	end

	local function simpleStatement(): any
		local tok = toks[p]
		local k = tok.t
		if k == "print" or k == "printf" then
			advance()
			local args = {}
			local saved = noGt
			noGt = true
			if not ENDS_PRINT[toks[p].t] then
				args = exprList()
			end
			noGt = saved
			if #args == 1 and args[1].k == "group" then
				args = args[1].items
			end
			for _, arg in ipairs(args) do
				if arg.k == "group" then
					fail("a parenthesised list is only print's arguments, or the keys of an `in` test", tok)
				end
			end
			if k == "printf" and #args == 0 then
				fail("printf needs a format", tok)
			end
			local dest, append
			local r = toks[p].t
			if r == ">" or r == ">>" then
				advance()
				append = r == ">>"
				dest = concat()
			elseif r == "|" then
				fail(PRINT_PIPE, nil, 2)
			end
			return { k = k, args = args, dest = dest, append = append }
		elseif k == "delete" then
			advance()
			local array = arrayName()
			if toks[p].t == "[" then
				advance()
				local subs = exprList()
				expect("]")
				return { k = "delete", array = array, subs = subs }
			end
			return { k = "delete", array = array }
		elseif k == "next" or k == "nextfile" then
			if context == "BEGIN" or context == "END" then
				fail(string.format("%s cannot be used in a %s action", k, context), tok)
			end
			advance()
			return { k = k }
		elseif k == "exit" or k == "return" then
			if k == "return" and not params then
				fail("return is only allowed inside a function", tok)
			end
			advance()
			local value = if ENDS_STATEMENT[toks[p].t] then nil else expr()
			return { k = k, e = value }
		elseif k == "break" or k == "continue" then
			if loopDepth == 0 then
				fail(k .. " is only allowed inside a loop", tok)
			end
			advance()
			return { k = k }
		end
		return { k = "expr", e = expr() }
	end

	local function loopBody(): any
		skipNewlines()
		loopDepth += 1
		local body = statement()
		loopDepth -= 1
		return body
	end

	local function condition(): any
		expect("(")
		local saved = noGt
		noGt = false
		skipNewlines()
		local c = expr()
		skipNewlines()
		expect(")")
		noGt = saved
		return c
	end

	statement = function(): any
		local k = toks[p].t
		if k == "{" then
			return block()
		elseif k == "if" then
			advance()
			local c = condition()
			skipNewlines()
			local a = statement()
			local save = p
			while toks[p].t == "nl" or toks[p].t == ";" do
				p += 1
			end
			if toks[p].t == "else" then
				advance()
				skipNewlines()
				return { k = "if", c = c, a = a, b = statement() }
			end
			p = save
			return { k = "if", c = c, a = a }
		elseif k == "while" then
			advance()
			local c = condition()
			return { k = "while", c = c, body = loopBody() }
		elseif k == "do" then
			advance()
			local body = loopBody()
			while toks[p].t == "nl" or toks[p].t == ";" do
				p += 1
			end
			expect("while")
			local c = condition()
			terminator()
			return { k = "do", c = c, body = body }
		elseif k == "for" then
			advance()
			expect("(")
			if kind() == "name" and kind(1) == "in" and kind(2) == "name" and kind(3) == ")" then
				local var = varRef(advance().v)
				advance()
				local array = arrayName()
				expect(")")
				return { k = "forin", var = var, array = array, body = loopBody() }
			end
			local init, c, step
			if toks[p].t ~= ";" then
				init = expr()
			end
			expect(";")
			skipNewlines()
			if toks[p].t ~= ";" then
				c = expr()
			end
			expect(";")
			skipNewlines()
			if toks[p].t ~= ")" then
				step = expr()
			end
			expect(")")
			return { k = "for", init = init, c = c, step = step, body = loopBody() }
		elseif k == ";" then
			advance()
			return { k = "nop" }
		end
		local simple = simpleStatement()
		terminator()
		return simple
	end

	block = function(): any
		expect("{")
		local body = {}
		while true do
			while toks[p].t == "nl" or toks[p].t == ";" do
				p += 1
			end
			if toks[p].t == "}" then
				break
			end
			if toks[p].t == "eof" then
				fail("missing `}'")
			end
			body[#body + 1] = statement()
		end
		advance()
		return { k = "block", body = body }
	end

	local program = { begins = {}, ends = {}, rules = {}, functions = functions }
	while true do
		while toks[p].t == "nl" or toks[p].t == ";" do
			p += 1
		end
		local tok = toks[p]
		if tok.t == "eof" then
			break
		end
		if tok.t == "BEGIN" or tok.t == "END" then
			advance()
			skipNewlines()
			if toks[p].t ~= "{" then
				fail(tok.t .. " needs an action, as " .. tok.t .. " { ... }", tok)
			end
			context = tok.t
			local body = block()
			context = "main"
			local list = if tok.t == "BEGIN" then program.begins else program.ends
			list[#list + 1] = body
		elseif tok.t == "function" then
			advance()
			local nameTok = toks[p]
			if nameTok.t ~= "name" and nameTok.t ~= "funcname" then
				fail("expected a function name, found " .. describe(nameTok))
			end
			if functions[nameTok.v] then
				fail(string.format("function `%s' is defined twice", nameTok.v), nameTok)
			end
			advance()
			expect("(")
			local names: { string } = {}
			local slots: { [string]: number } = {}
			skipNewlines()
			while toks[p].t ~= ")" do
				local paramTok = toks[p]
				if paramTok.t ~= "name" then
					fail("expected a parameter name, found " .. describe(paramTok))
				end
				if slots[paramTok.v] then
					fail(string.format("parameter `%s' is listed twice", paramTok.v), paramTok)
				end
				advance()
				names[#names + 1] = paramTok.v
				slots[paramTok.v] = #names
				if toks[p].t == "," then
					advance()
					skipNewlines()
				elseif toks[p].t ~= ")" then
					fail("expected `,' or `)', found " .. describe(toks[p]))
				end
			end
			advance()
			skipNewlines()
			local fn = { name = nameTok.v, params = names }
			-- Registered before the body is parsed, so it can call itself.
			functions[nameTok.v] = fn
			params = slots
			context = "function"
			fn.body = block()
			params = nil
			context = "main"
		else
			local rule: any = {}
			if tok.t ~= "{" then
				rule.pattern = expr()
				if toks[p].t == "," then
					advance()
					skipNewlines()
					rule.to = expr()
				end
			end
			if toks[p].t == "{" then
				rule.body = block()
			elseif not ENDS_STATEMENT[toks[p].t] then
				fail("unexpected " .. describe(toks[p]) .. " after a pattern")
			end
			program.rules[#program.rules + 1] = rule
		end
	end

	for _, call in ipairs(calls) do
		local fn = functions[call.name]
		if not fn then
			local why = if GAWK_ONLY[call.name]
				then string.format(" — %s is a gawk extension, and this is POSIX awk", call.name)
				else ""
			fail(string.format("function `%s' is not defined%s", call.name, why), call.tok, 2)
		end
		if call.n > #fn.params then
			fail(string.format("function `%s' takes %d argument%s, called with %d", call.name,
				#fn.params, if #fn.params == 1 then "" else "s", call.n), call.tok, 2)
		end
	end
	return program, warnings
end

-- Values
-- Three kinds, as POSIX has them: a number, a string, and a "strnum", text
-- that came from input (a field, getline, split, ARGV, ENVIRON, -v). A strnum
-- compares as a number when all of it looks like one, so `$1 == 10` holds for
-- a field reading `10.0` while the constant `"10.0" == 10` does not. Uninitialized
-- is its own value, both "" and 0.
--
-- A strnum is a table `{ s = text, n = cache }`, `n` being nil until asked,
-- false when the text is not numeric. Nothing mutates `s`, so sharing one
-- between two variables is the same as copying it.
local UNINIT = table.freeze({})

local function strnum(s: string): any
	return { s = s }
end

-- A field past NF, or one a longer assignment filled in. It is the empty
-- string read from input, not an unset variable: `$9 == 0` is false where
-- `unset == 0` is true.
local EMPTY = table.freeze({ s = "", n = false })

-- A number at the front of `s` from `at`, the way strtod reads one. tonumber is
-- the wrong tool twice over: it wants the whole string, and it reads hex, where
-- awk reads `0x1A` as 0.
local function scanNumber(s: string, at: number): (number?, number)
	local text = s:match("^[+-]?%d+%.?%d*", at) or s:match("^[+-]?%.%d+", at)
	if not text then
		-- gawk reads these only with a sign.
		local special = s:match("^[+-][iI][nN][fF]", at) or s:match("^[+-][nN][aA][nN]", at)
		if special then
			local value = if special:sub(2, 2):lower() == "i" then math.huge else 0 / 0
			return if special:sub(1, 1) == "-" then -value else value, at + #special
		end
		return nil, at
	end
	local after = at + #text
	local exponent = s:match("^[eE][+-]?%d+", after)
	if exponent then
		text ..= exponent
		after += #exponent
	end
	return tonumber((text:gsub("^%+", ""))), after
end

local function strtod(s: string): number
	return (scanNumber(s, s:match("^[ \t\n\r\f\v]*()") :: number)) or 0
end

local function numericValue(s: string): number | false
	local number, after = scanNumber(s, s:match("^[ \t\n]*()") :: number)
	if number ~= nil and s:match("^[ \t\n]*$", after) then
		return number
	end
	return false
end

local function isNumeric(v: any): boolean
	local t = type(v)
	if t == "number" then
		return true
	elseif t == "string" then
		return false
	elseif v == UNINIT then
		return true
	end
	local n = v.n
	if n == nil then
		n = numericValue(v.s)
		v.n = n
	end
	return n ~= false
end

local function toNum(v: any): number
	local t = type(v)
	if t == "number" then
		return v
	elseif t == "string" then
		return strtod(v)
	elseif v == UNINIT then
		return 0
	end
	local n = v.n
	if n == nil then
		n = numericValue(v.s)
		v.n = n
	end
	return if n then n else strtod(v.s)
end

local function toBool(v: any): boolean
	local t = type(v)
	if t == "number" then
		return v ~= 0
	elseif t == "string" then
		return v ~= ""
	elseif v == UNINIT then
		return false
	end
	if isNumeric(v) then
		return v.n ~= 0
	end
	return v.s ~= ""
end

local function trunc(n: number): number
	return if n >= 0 then math.floor(n) else math.ceil(n)
end

local function fatal(message: string): never
	error({ awk = message }, 0)
end

-- gawk's spelling of the four values printf cannot write portably: Luau hands
-- `-nan(ind)` back on Windows and `nan` elsewhere.
local function special(n: number): string?
	if n ~= n then
		return if string.format("%f", n):find("-", 1, true) then "-nan" else "+nan"
	elseif n == math.huge then
		return "+inf"
	elseif n == -math.huge then
		return "-inf"
	end
	return nil
end

-- Output
-- printf's grammar, awk's version of it: `%c` of a number is that character,
-- `%d` of "3abc" is 3 with no complaint, arguments are never recycled over the
-- format, and escapes were the lexer's job. The shell's printf differs on all
-- four, so this is its own. Padding is done here because Luau's string.format
-- refuses a width or precision over 99.
local CONVERSIONS = "diouxXeEfFgGcs"

local function pad(body: string, flags: string, width: number?, zeroable: boolean): string
	if not width or #body >= width then
		return body
	end
	if flags:find("-", 1, true) then
		return body .. string.rep(" ", width - #body)
	end
	if zeroable and flags:find("0", 1, true) then
		local sign = body:match("^[+%- ]") or ""
		local prefix = body:match("^0[xX]", #sign + 1) or ""
		local head = #sign + #prefix
		return body:sub(1, head) .. string.rep("0", width - #body) .. body:sub(head + 1)
	end
	return string.rep(" ", width - #body) .. body
end

local toStr

local function formatOne(rt: any, flags: string, width: number?, precision: number?,
	conv: string, arg: any): string
	if conv == "c" then
		local text
		if isNumeric(arg) then
			local code = toNum(arg)
			text = if code == code and math.abs(code) ~= math.huge
				then string.char(trunc(code) % 256) else ""
		else
			text = toStr(rt, arg):sub(1, 1)
		end
		return pad(text, flags, width, false)
	elseif conv == "s" then
		local text = toStr(rt, arg)
		if precision then
			text = text:sub(1, precision)
		end
		return pad(text, flags, width, false)
	end
	local n = toNum(arg)
	-- gawk prints these bare, whatever width was asked for.
	local odd = special(n)
	if odd then
		return odd
	end
	if precision and precision > 99 then
		fatal("printf precision above 99 is not supported")
	end
	local exact = if precision then "." .. precision else ""
	local body
	if conv == "d" or conv == "i" then
		n = trunc(n)
		local signs = flags:gsub("[-0#]", "")
		body = if math.abs(n) < 2 ^ 63
			then string.format("%" .. signs .. exact .. "d", n)
			else string.format("%" .. signs .. ".0f", n)
	elseif conv == "o" or conv == "x" or conv == "X" or conv == "u" then
		n = trunc(n)
		local signs = flags:gsub("[-0+ ]", "")
		body = if math.abs(n) < 2 ^ 63
			then string.format("%" .. signs .. exact .. conv, n)
			else string.format("%.0f", n)
	else
		local signs = flags:gsub("[-0]", "")
		body = string.format("%" .. signs .. "." .. (precision or 6) .. (if conv == "F" then "f" else conv), n)
	end
	return pad(body, flags, width, precision == nil or not ("diouxX"):find(conv, 1, true))
end

local function sprintf(rt: any, format: string, values: { any }, first: number): string
	local out: { string } = {}
	local nextArg = first
	local function take(): any
		if nextArg > #values then
			fatal("not enough arguments to satisfy format string `" .. format .. "'")
		end
		nextArg += 1
		return values[nextArg - 1]
	end
	local i = 1
	while i <= #format do
		local pct = format:find("%", i, true)
		if not pct then
			out[#out + 1] = format:sub(i)
			break
		end
		out[#out + 1] = format:sub(i, pct - 1)
		local j = pct + 1
		local flags = format:match("^[-+ #0]*", j) :: string
		j += #flags
		local width, precision
		if format:sub(j, j) == "*" then
			width = trunc(toNum(take()))
			j += 1
			if width < 0 then
				flags ..= "-"
				width = -width
			end
		else
			local digits = format:match("^%d*", j) :: string
			j += #digits
			width = tonumber(digits)
		end
		if format:sub(j, j) == "." then
			j += 1
			if format:sub(j, j) == "*" then
				precision = trunc(toNum(take()))
				j += 1
				if precision < 0 then
					precision = nil
				end
			else
				local digits = format:match("^%d*", j) :: string
				j += #digits
				precision = tonumber(digits) or 0
			end
		end
		j += #(format:match("^[hlLqjzt]*", j) :: string)
		local conv = format:sub(j, j)
		if conv == "%" then
			out[#out + 1] = "%"
		elseif conv == "" or not CONVERSIONS:find(conv, 1, true) then
			-- Not a conversion: printed as written, the way gawk does.
			out[#out + 1] = format:sub(pct, j)
		else
			if width and width > MAX_OUTPUT then
				fatal(string.format("printf width %d is past the %d byte output limit", width, MAX_OUTPUT))
			end
			out[#out + 1] = formatOne(rt, flags, width, precision, conv, take())
		end
		i = j + 1
	end
	return table.concat(out)
end

-- A number as text. Integral values are written as integers, all their digits
-- (`2^70` is 1180591620717411303424); the rest go through CONVFMT or OFMT. A
-- format that is not a number conversion is ignored, as gawk ignores it, since
-- `CONVFMT = "%s"` would otherwise format a number by formatting that number.
local function formatNumber(rt: any, n: number, format: string): string
	local odd = special(n)
	if odd then
		return odd
	end
	if n == math.floor(n) then
		if n == 0 then
			return "0"
		end
		return string.format(if math.abs(n) < 2 ^ 63 then "%d" else "%.0f", n)
	end
	if format == "%.6g" then
		return string.format("%.6g", n)
	end
	local usable = rt.formats[format]
	if usable == nil then
		local conv = format:match("^[^%%]*%%[-+ #0]*%d*%.?%d*([%a%%])")
		usable = conv ~= nil and ("diouxXeEfFgG"):find(conv, 1, true) ~= nil
			and select(2, format:gsub("%%", "")) == 1
		rt.formats[format] = usable
	end
	return if usable then sprintf(rt, format, { n }, 1) else string.format("%.6g", n)
end

local function formatName(rt: any, name: string): string
	local value = rt.G[name]
	if type(value) == "string" then
		return value
	elseif type(value) == "table" and value.s then
		return value.s
	end
	return "%.6g"
end

toStr = function(rt: any, v: any): string
	local t = type(v)
	if t == "string" then
		return v
	elseif t == "number" then
		return formatNumber(rt, v, formatName(rt, "CONVFMT"))
	elseif v == UNINIT then
		return ""
	end
	return v.s
end

local function outStr(rt: any, v: any): string
	if type(v) == "number" then
		return formatNumber(rt, v, formatName(rt, "OFMT"))
	end
	return toStr(rt, v)
end

-- Arrays
-- Iterated in insertion order. POSIX leaves `for (k in a)` unordered and every
-- awk picks something; first-seen is the order a count or a dedup reads best in.
local function newArray(): any
	return { isArray = true, map = {}, keys = {}, pos = {}, count = 0 }
end

local function aset(a: any, key: string, v: any)
	if a.map[key] == nil then
		a.count += 1
		a.keys[#a.keys + 1] = key
		a.pos[key] = #a.keys
	end
	a.map[key] = v
end

-- Referencing an element creates it, which is awk: `if (a[k] == "")` leaves
-- `k in a` true afterwards.
local function aget(a: any, key: string): any
	local v = a.map[key]
	if v == nil then
		v = UNINIT
		aset(a, key, v)
	end
	return v
end

local function adelete(a: any, key: string)
	if a.map[key] == nil then
		return
	end
	a.map[key] = nil
	a.keys[a.pos[key]] = false
	a.pos[key] = nil
	a.count -= 1
	if #a.keys > 32 and a.count < #a.keys / 2 then
		local keys, pos = {}, {}
		for _, k in ipairs(a.keys) do
			if k then
				keys[#keys + 1] = k
				pos[k] = #keys
			end
		end
		a.keys, a.pos = keys, pos
	end
end

local function aclear(a: any)
	a.map, a.keys, a.pos, a.count = {}, {}, {}, 0
end

local function isArray(v: any): boolean
	return type(v) == "table" and v.isArray == true
end

-- Interpreter

local NEXT, NEXTFILE, EXIT = { signal = "next" }, { signal = "nextfile" }, { signal = "exit" }

local function tick(rt: any)
	local steps = rt.steps + 1
	rt.steps = steps
	if steps % 1024 == 0 then
		if os.clock() - rt.started > MAX_SECONDS then
			fatal(string.format("still running after %d seconds, so it was stopped; the " ..
				"program may not terminate — check the loop conditions", MAX_SECONDS))
		end
		rt.breathe()
	end
end

local function regexFor(rt: any, source: string): any
	local program = rt.regexes[source]
	if program then
		return program
	end
	local compiled, err = Regex.compile(source, { ere = true })
	if not compiled then
		fatal(string.format("invalid regex /%s/: %s", source, tostring(err)))
	end
	if rt.regexCount >= 256 then
		rt.regexes, rt.regexCount = {}, 0
	end
	rt.regexes[source] = compiled
	rt.regexCount += 1
	return compiled
end

local EVAL: { [string]: (any, any) -> any } = {}
local EXEC: { [string]: (any, any) -> string? } = {}

local function eval(rt: any, node: any): any
	return EVAL[node.k](rt, node)
end

local function exec(rt: any, node: any): string?
	tick(rt)
	return EXEC[node.k](rt, node)
end

local function regexOf(rt: any, node: any): any
	if node.k == "regex" then
		return node.prog
	end
	return regexFor(rt, toStr(rt, eval(rt, node)))
end

-- Records and fields
-- $0 is split lazily, on the first field or NF read, with the FS in force when
-- the record was read: changing FS applies from the next record, which is what
-- makes `{ FS = ":"; $0 = $0 }` the idiom for re-splitting now.

local function setRecord(rt: any, text: string)
	rt.record = text
	rt.fields = nil
	rt.dirty = false
	rt.recordValue = nil
	rt.recordFS = toStr(rt, rt.G.FS)
	rt.paragraph = toStr(rt, rt.G.RS) == ""
end

local function splitRegex(s: string, program: any): { string }
	local out: { string } = {}
	local from, search = 1, 1
	while search <= #s do
		local a, b = program:find(s, search)
		if not a then
			break
		end
		if (b :: number) < a then
			-- An empty match separates nothing.
			search = a + 1
		else
			out[#out + 1] = s:sub(from, a - 1)
			from = (b :: number) + 1
			search = from
		end
	end
	out[#out + 1] = s:sub(from)
	return out
end

-- FS " " is runs of blanks and newlines with the ends trimmed, one other
-- character is that character literally, "" is every character, and anything
-- longer is a regex. In paragraph mode a newline always separates too.
local function splitWith(rt: any, s: string, fs: string, paragraph: boolean): { string }
	local out: { string } = {}
	if fs == " " then
		for word in s:gmatch("[^ \t\n]+") do
			out[#out + 1] = word
		end
		return out
	end
	if s == "" then
		return out
	end
	if fs == "" then
		for i = 1, #s do
			out[i] = s:sub(i, i)
		end
		return out
	end
	if #fs == 1 and not paragraph then
		local from = 1
		while true do
			local at = s:find(fs, from, true)
			if not at then
				out[#out + 1] = s:sub(from)
				return out
			end
			out[#out + 1] = s:sub(from, at - 1)
			from = at + 1
		end
	end
	local source = if #fs == 1 then Regex.escape(fs) else fs
	if paragraph then
		source = "(" .. source .. ")|\n"
	end
	return splitRegex(s, regexFor(rt, source))
end

local function ensureFields(rt: any): { any }
	local fields = rt.fields
	if fields then
		return fields
	end
	local parts = splitWith(rt, rt.record, rt.recordFS, rt.paragraph)
	fields = table.create(#parts)
	for i, part in ipairs(parts) do
		fields[i] = strnum(part)
	end
	rt.fields = fields
	rt.nf = #parts
	return fields
end

local function recordText(rt: any): string
	if rt.dirty then
		local ofs = toStr(rt, rt.G.OFS)
		local parts = table.create(rt.nf)
		for i = 1, rt.nf do
			parts[i] = toStr(rt, rt.fields[i])
		end
		rt.record = table.concat(parts, ofs)
		rt.dirty = false
		rt.recordValue = nil
	end
	return rt.record
end

local function getField(rt: any, i: number): any
	if i == 0 then
		local value = rt.recordValue
		if not value then
			value = strnum(recordText(rt))
			rt.recordValue = value
		end
		return value
	end
	local fields = ensureFields(rt)
	if i > rt.nf then
		return EMPTY
	end
	return fields[i]
end

local function fieldIndex(rt: any, node: any): number
	local n = toNum(eval(rt, node))
	if not (n >= 0) then
		fatal("attempt to access field " .. toStr(rt, trunc(n)))
	end
	n = math.floor(n)
	if n > MAX_FIELD then
		fatal(string.format("field $%d is past the %d field limit", n, MAX_FIELD))
	end
	return n
end

local function setField(rt: any, i: number, v: any)
	if i == 0 then
		setRecord(rt, toStr(rt, v))
		return
	end
	local fields = ensureFields(rt)
	for j = rt.nf + 1, i - 1 do
		fields[j] = EMPTY
	end
	fields[i] = v
	if i > rt.nf then
		rt.nf = i
	end
	rt.dirty = true
	rt.recordValue = nil
end

local function setNF(rt: any, value: number)
	local n = trunc(value)
	if not (n >= 0) then
		fatal("NF set to a negative value")
	end
	if n > MAX_FIELD then
		fatal(string.format("NF set past the %d field limit", MAX_FIELD))
	end
	local fields = ensureFields(rt)
	for j = rt.nf + 1, n do
		fields[j] = EMPTY
	end
	for j = n + 1, rt.nf do
		fields[j] = nil
	end
	rt.nf = n
	rt.dirty = true
	rt.recordValue = nil
end

-- RS "\n" or any one character splits on it; "" is paragraph mode, records
-- separated by blank lines; anything longer is a regex. A last record with no
-- separator after it is still a record.
local function readRecord(rt: any, src: any): string?
	local text, pos = src.text, src.pos
	local rs = toStr(rt, rt.G.RS)
	if rs == "" then
		pos = text:match("^\n*()", pos) :: number
		if pos > #text then
			src.pos = pos
			return nil
		end
		local a, b = text:find("\n\n+", pos)
		if a then
			src.pos = (b :: number) + 1
			return text:sub(pos, a - 1)
		end
		src.pos = #text + 1
		return (text:sub(pos):gsub("\n+$", ""))
	end
	if pos > #text then
		return nil
	end
	if #rs == 1 then
		local at = text:find(rs, pos, true)
		if at then
			src.pos = at + 1
			return text:sub(pos, at - 1)
		end
	else
		local a, b = regexFor(rt, rs):find(text, pos)
		if a and (b :: number) >= a then
			src.pos = (b :: number) + 1
			return text:sub(pos, a - 1)
		end
	end
	src.pos = #text + 1
	return text:sub(pos)
end

-- Variables

local function scalarError(name: string): never
	fatal(string.format("attempt to use array `%s' in a scalar context", name))
end

local function getArray(rt: any, node: any): any
	local k = node.k
	if k == "global" then
		local v = rt.G[node.name]
		if v == nil or v == UNINIT then
			v = newArray()
			rt.G[node.name] = v
		elseif not isArray(v) then
			fatal(string.format("attempt to use scalar `%s' as an array", node.name))
		end
		return v
	elseif k == "local" then
		local v = rt.frame[node.slot]
		if v == nil or v == UNINIT then
			v = newArray()
			rt.frame[node.slot] = v
		elseif not isArray(v) then
			fatal(string.format("attempt to use scalar `%s' as an array", node.name))
		end
		v.pending = nil
		return v
	end
	fatal(string.format("attempt to use `%s' as an array", node.name or "?"))
end

local function subscript(rt: any, subs: { any }): string
	if #subs == 1 then
		return toStr(rt, eval(rt, subs[1]))
	end
	local parts = table.create(#subs)
	for i, sub in ipairs(subs) do
		parts[i] = toStr(rt, eval(rt, sub))
	end
	return table.concat(parts, toStr(rt, rt.G.SUBSEP))
end

-- An lvalue resolved once, so `a[i++] += 1` evaluates its subscript once.
local function locate(rt: any, node: any): (string, any, any)
	local k = node.k
	if k == "field" then
		return "f", fieldIndex(rt, node.index), nil
	elseif k == "index" then
		return "a", getArray(rt, node.array), subscript(rt, node.subs)
	end
	return k, node, nil
end

local function load(rt: any, kind: string, a: any, b: any): any
	if kind == "f" then
		return getField(rt, a)
	elseif kind == "a" then
		return aget(a, b)
	end
	return eval(rt, a)
end

local function store(rt: any, kind: string, a: any, b: any, v: any)
	if kind == "f" then
		setField(rt, a, v)
	elseif kind == "a" then
		aset(a, b, v)
	elseif kind == "nf" then
		setNF(rt, toNum(v))
	elseif kind == "global" then
		if isArray(rt.G[a.name]) then
			scalarError(a.name)
		end
		rt.G[a.name] = v
	else
		local current = rt.frame[a.slot]
		if isArray(current) and not current.pending then
			scalarError(a.name)
		end
		rt.frame[a.slot] = v
	end
end

local function assignTo(rt: any, node: any, v: any)
	local kind, a, b = locate(rt, node)
	store(rt, kind, a, b, v)
end

-- A `name=value` operand or -v: the value is escape-processed and is a strnum.
local function assignVariable(rt: any, name: string, raw: string)
	local value = strnum(unescape(raw))
	if name == "NF" then
		setNF(rt, toNum(value))
	elseif rt.functions[name] then
		fatal(string.format("cannot assign to `%s', which is a function", name))
	elseif isArray(rt.G[name]) then
		scalarError(name)
	else
		rt.G[name] = value
	end
end

local function arith(op: string, x: number, y: number): number
	if op == "+" then
		return x + y
	elseif op == "-" then
		return x - y
	elseif op == "*" then
		return x * y
	elseif op == "/" then
		if y == 0 then
			fatal("division by zero attempted")
		end
		return x / y
	elseif op == "%" then
		if y == 0 then
			fatal("division by zero attempted in `%'")
		end
		return math.fmod(x, y)
	end
	return x ^ y
end

local function compare(rt: any, a: any, b: any): number
	if isNumeric(a) and isNumeric(b) then
		local x, y = toNum(a), toNum(b)
		if x ~= x then
			return if y ~= y then 0 else 1
		elseif y ~= y then
			return -1
		end
		return if x < y then -1 elseif x > y then 1 else 0
	end
	local x, y = toStr(rt, a), toStr(rt, b)
	return if x < y then -1 elseif x > y then 1 else 0
end

EVAL.num = function(_, node)
	return node.v
end
EVAL.str = EVAL.num
EVAL.regex = function(rt, node)
	return if node.prog:find(recordText(rt)) then 1 else 0
end
EVAL.global = function(rt, node)
	local v = rt.G[node.name]
	if v == nil then
		return UNINIT
	end
	if isArray(v) then
		scalarError(node.name)
	end
	return v
end
EVAL["local"] = function(rt, node)
	local v = rt.frame[node.slot]
	if v == nil then
		return UNINIT
	end
	if isArray(v) then
		if v.pending then
			return UNINIT
		end
		scalarError(node.name)
	end
	return v
end
EVAL.nf = function(rt)
	ensureFields(rt)
	return rt.nf
end
EVAL.field = function(rt, node)
	return getField(rt, fieldIndex(rt, node.index))
end
EVAL.index = function(rt, node)
	local a = getArray(rt, node.array)
	return aget(a, subscript(rt, node.subs))
end
EVAL.concat = function(rt, node)
	local items = node.items
	local parts = table.create(#items)
	for i, item in ipairs(items) do
		parts[i] = toStr(rt, eval(rt, item))
	end
	return table.concat(parts)
end
EVAL.unary = function(rt, node)
	local v = eval(rt, node.a)
	if node.op == "!" then
		return if toBool(v) then 0 else 1
	end
	local n = toNum(v)
	return if node.op == "-" then -n else n
end
EVAL.binop = function(rt, node)
	return arith(node.op, toNum(eval(rt, node.a)), toNum(eval(rt, node.b)))
end
EVAL.cmp = function(rt, node)
	local c = compare(rt, eval(rt, node.a), eval(rt, node.b))
	local op = node.op
	local yes
	if op == "<" then
		yes = c < 0
	elseif op == "<=" then
		yes = c <= 0
	elseif op == "==" then
		yes = c == 0
	elseif op == "!=" then
		yes = c ~= 0
	elseif op == ">=" then
		yes = c >= 0
	else
		yes = c > 0
	end
	return if yes then 1 else 0
end
EVAL.match = function(rt, node)
	local subject = toStr(rt, eval(rt, node.a))
	local hit = regexOf(rt, node.b):find(subject) ~= nil
	return if hit ~= node.neg then 1 else 0
end
EVAL["and"] = function(rt, node)
	return if toBool(eval(rt, node.a)) and toBool(eval(rt, node.b)) then 1 else 0
end
EVAL["or"] = function(rt, node)
	return if toBool(eval(rt, node.a)) or toBool(eval(rt, node.b)) then 1 else 0
end
EVAL.cond = function(rt, node)
	return if toBool(eval(rt, node.c)) then eval(rt, node.a) else eval(rt, node.b)
end
EVAL["in"] = function(rt, node)
	local key = subscript(rt, node.keys)
	return if getArray(rt, node.array).map[key] ~= nil then 1 else 0
end
EVAL.assign = function(rt, node)
	local kind, a, b = locate(rt, node.target)
	local v
	if node.op == "=" then
		v = eval(rt, node.value)
	else
		local current = toNum(load(rt, kind, a, b))
		v = arith(node.op:sub(1, 1), current, toNum(eval(rt, node.value)))
	end
	store(rt, kind, a, b, v)
	return v
end
EVAL.incr = function(rt, node)
	local kind, a, b = locate(rt, node.target)
	local old = toNum(load(rt, kind, a, b))
	store(rt, kind, a, b, old + node.delta)
	return if node.post then old else old + node.delta
end
EVAL.group = function()
	fatal("a parenthesised list is only print's arguments")
end

-- Scalars are passed by value and arrays by reference. An argument that is an
-- untouched variable could turn out to be either, so it goes in as an empty
-- array marked pending: if the function uses it as an array, the caller's
-- variable becomes that array afterwards, and if not, nothing has changed.
EVAL.call = function(rt, node)
	local fn = rt.functions[node.name]
	local frame = {}
	local binds
	for i, arg in ipairs(node.args) do
		local k = arg.k
		if k == "global" or k == "local" then
			local current = if k == "global" then rt.G[arg.name] else rt.frame[arg.slot]
			if isArray(current) then
				frame[i] = current
			elseif current == nil or current == UNINIT then
				local array = newArray()
				array.pending = true
				frame[i] = array
				binds = binds or {}
				binds[#binds + 1] = { arg, array }
			else
				frame[i] = current
			end
		else
			frame[i] = eval(rt, arg)
		end
	end
	if rt.depth >= MAX_DEPTH then
		fatal(string.format("function call depth exceeds %d", MAX_DEPTH))
	end
	local saved = rt.frame
	rt.frame = frame
	rt.depth += 1
	local signal = exec(rt, fn.body)
	rt.frame = saved
	rt.depth -= 1
	local value = UNINIT
	if signal == "return" then
		value = rt.returnValue
		rt.returnValue = nil
	end
	if binds then
		for _, bind in ipairs(binds) do
			local arg, array = bind[1], bind[2]
			if not array.pending then
				if arg.k == "global" then
					rt.G[arg.name] = array
				else
					rt.frame[arg.slot] = array
				end
			end
		end
	end
	return value
end

-- Input
-- ARGV is read as the input goes, not once up front, so a BEGIN that edits it
-- changes what is read. An operand shaped `name=value` is an assignment made
-- when it is reached. With no file operands at all, the input is stdin.
local function readInput(rt: any, name: string): string
	if name == "-" or name == "/dev/stdin" then
		if rt.stdin == nil then
			fatal("`" .. name .. "' names standard input, and nothing was piped in")
		end
		return rt.stdin
	elseif name == "/dev/null" then
		return ""
	end
	local text, err = rt.host.read(name)
	if text == nil then
		fatal(string.format("cannot open file `%s' for reading: %s", name, tostring(err)))
	end
	return text
end

local function nextMainRecord(rt: any): (string?, string?)
	while true do
		local current = rt.current
		if current then
			local text = readRecord(rt, current)
			if text then
				return text
			end
			rt.current = nil
		end
		local opened = false
		while not opened do
			if rt.argIndex >= toNum(rt.G.ARGC) then
				break
			end
			local index = rt.argIndex
			rt.argIndex += 1
			local argv = rt.G.ARGV
			local value = if isArray(argv) then argv.map[tostring(index)] else nil
			local arg = if value ~= nil then toStr(rt, value) else ""
			if arg ~= "" then
				local name, raw = arg:match("^([%a_][%w_]*)=(.*)$")
				if name then
					assignVariable(rt, name, raw)
				else
					rt.usedFile = true
					rt.current = { text = readInput(rt, arg), pos = 1 }
					rt.G.FILENAME = arg
					rt.G.FNR = 0
					opened = true
				end
			end
		end
		if not opened then
			if rt.usedFile or rt.stdinTaken then
				return nil
			end
			rt.stdinTaken = true
			if rt.stdin == nil then
				return nil, "needs input: a file operand, or text piped in"
			end
			rt.current = { text = rt.stdin, pos = 1 }
			rt.G.FNR = 0
		end
	end
end

EVAL.getline = function(rt, node)
	local text
	if node.file then
		local name = toStr(rt, eval(rt, node.file))
		local reader = rt.readers[name]
		if not reader then
			local content
			if name == "-" or name == "/dev/stdin" then
				content = rt.stdin
			elseif name == "/dev/null" then
				content = ""
			else
				content = rt.host.read(name)
			end
			if content == nil then
				return -1
			end
			reader = { text = content, pos = 1 }
			rt.readers[name] = reader
		end
		text = readRecord(rt, reader)
		if text == nil then
			return 0
		end
	else
		local err
		text, err = nextMainRecord(rt)
		if text == nil then
			return if err then -1 else 0
		end
		rt.G.NR = toNum(rt.G.NR) + 1
		rt.G.FNR = toNum(rt.G.FNR) + 1
	end
	if node.target then
		assignTo(rt, node.target, strnum(text))
	else
		setRecord(rt, text)
	end
	return 1
end

-- Output
-- Files are buffered and written once, at close() or at the end, so a program
-- that prints ten thousand lines to one file is one write and one undo step.

local function emit(rt: any, text: string)
	rt.bytes += #text
	if rt.bytes > MAX_OUTPUT then
		fatal(string.format("output exceeds %d bytes", MAX_OUTPUT))
	end
end

local function flushFile(rt: any, name: string)
	local file = rt.files[name]
	rt.files[name] = nil
	local err = rt.host.write(name, table.concat(file.chunks), file.append)
	if err then
		rt.err[#rt.err + 1] = string.format("awk: cannot write to `%s': %s\n", name, tostring(err))
		rt.writeFailed = true
	end
end

local function send(rt: any, node: any, text: string)
	local name = if node.dest then toStr(rt, eval(rt, node.dest)) else "/dev/stdout"
	if name == "/dev/null" then
		return
	end
	emit(rt, text)
	if name == "/dev/stdout" or name == "-" then
		rt.out[#rt.out + 1] = text
	elseif name == "/dev/stderr" then
		rt.err[#rt.err + 1] = text
	else
		local file = rt.files[name]
		if not file then
			file = { chunks = {}, append = node.append == true }
			rt.files[name] = file
			rt.fileOrder[#rt.fileOrder + 1] = name
		end
		file.chunks[#file.chunks + 1] = text
	end
end

-- Builtins

local BUILTIN: { [string]: (any, { any }) -> any } = {}

BUILTIN.length = function(rt, args)
	local arg = args[1]
	if not arg then
		return #recordText(rt)
	end
	if arg.k == "global" or arg.k == "local" then
		local v = if arg.k == "global" then rt.G[arg.name] else rt.frame[arg.slot]
		if isArray(v) then
			return v.count
		end
	end
	return #toStr(rt, eval(rt, arg))
end

-- gawk's rules, read off its do_substr: a start below 1 is 1 without
-- shortening the length, and both are truncated rather than rounded.
BUILTIN.substr = function(rt, args)
	local s = toStr(rt, eval(rt, args[1]))
	local start = toNum(eval(rt, args[2]))
	local length
	if args[3] then
		local l = toNum(eval(rt, args[3]))
		if not (l >= 1) then
			return ""
		end
		length = math.floor(l)
	end
	if not (start >= 1) then
		start = 1
	end
	local index = math.floor(start - 1)
	if s == "" or index >= #s then
		return ""
	end
	local count = length or (#s - index)
	if count > #s - index then
		count = #s - index
	end
	return s:sub(index + 1, index + count)
end

BUILTIN.index = function(rt, args)
	local s = toStr(rt, eval(rt, args[1]))
	local t = toStr(rt, eval(rt, args[2]))
	return s:find(t, 1, true) or 0
end

BUILTIN.split = function(rt, args)
	local s = toStr(rt, eval(rt, args[1]))
	local array = getArray(rt, args[2])
	local sep = args[3]
	local parts
	if sep and sep.k == "regex" then
		parts = if s == "" then {} else splitRegex(s, sep.prog)
	else
		local fs = toStr(rt, if sep then eval(rt, sep) else rt.G.FS)
		parts = splitWith(rt, s, fs, false)
	end
	aclear(array)
	for i, part in ipairs(parts) do
		aset(array, tostring(i), strnum(part))
	end
	return #parts
end

-- The replacement, as gawk's do_sub reads it by default (not its --posix
-- table): `&` is the match, `\&` a literal ampersand, `\\&` a backslash then
-- the match, `\\\&` a literal `\&`, `\\\\` two backslashes, and any other
-- backslash is itself. `true` in the result stands for the matched text.
local BS = "\\"
local function replacementParts(repl: string): { any }
	local parts: { any } = {}
	local buffer: { string } = {}
	local i = 1
	local function matched()
		parts[#parts + 1] = table.concat(buffer)
		parts[#parts + 1] = true
		buffer = {}
	end
	while i <= #repl do
		local c = repl:sub(i, i)
		if repl:sub(i, i + 3) == BS:rep(3) .. "&" then
			buffer[#buffer + 1] = BS .. "&"
			i += 4
		elseif repl:sub(i, i + 3) == BS:rep(4) then
			buffer[#buffer + 1] = BS:rep(2)
			i += 4
		elseif repl:sub(i, i + 2) == BS:rep(2) .. "&" then
			buffer[#buffer + 1] = BS
			matched()
			i += 3
		elseif repl:sub(i, i + 1) == BS .. "&" then
			buffer[#buffer + 1] = "&"
			i += 2
		elseif c == "&" then
			matched()
			i += 1
		else
			buffer[#buffer + 1] = c
			i += 1
		end
	end
	parts[#parts + 1] = table.concat(buffer)
	return parts
end

local function substitute(rt: any, args: { any }, global: boolean): number
	local program = regexOf(rt, args[1])
	local parts = replacementParts(toStr(rt, eval(rt, args[2])))
	local target = args[3] or RECORD
	local kind, a, b
	if isLvalue(target) then
		kind, a, b = locate(rt, target)
	end
	local s = toStr(rt, if kind then load(rt, kind :: string, a, b) else eval(rt, target))
	local out: { string } = {}
	local at, count, lastEnd, n = 1, 0, -1, #s
	while at <= n + 1 do
		local start, finish = program:find(s, at)
		if not start then
			break
		end
		if (finish :: number) < start and start == lastEnd + 1 then
			-- An empty match right where a real one ended is not another match:
			-- gsub(/b*/, "-") on "abc" is "-a-c-".
			if start > n then
				break
			end
			out[#out + 1] = s:sub(at, start)
			at = start + 1
		else
			out[#out + 1] = s:sub(at, start - 1)
			local matched = s:sub(start, finish)
			for _, part in ipairs(parts) do
				out[#out + 1] = if part == true then matched else part
			end
			count += 1
			if (finish :: number) < start then
				if start <= n then
					out[#out + 1] = s:sub(start, start)
				end
				at = start + 1
			else
				at = (finish :: number) + 1
				lastEnd = finish :: number
			end
			if not global then
				break
			end
		end
	end
	if count > 0 and kind then
		if at <= n then
			out[#out + 1] = s:sub(at)
		end
		store(rt, kind, a, b, table.concat(out))
	end
	return count
end

BUILTIN.sub = function(rt, args)
	return substitute(rt, args, false)
end
BUILTIN.gsub = function(rt, args)
	return substitute(rt, args, true)
end

BUILTIN.match = function(rt, args)
	local s = toStr(rt, eval(rt, args[1]))
	local start, finish = regexOf(rt, args[2]):find(s)
	if start then
		rt.G.RSTART = start
		rt.G.RLENGTH = (finish :: number) - start + 1
	else
		rt.G.RSTART = 0
		rt.G.RLENGTH = -1
	end
	return rt.G.RSTART
end

BUILTIN.sprintf = function(rt, args)
	local values = table.create(#args)
	for i, arg in ipairs(args) do
		values[i] = eval(rt, arg)
	end
	return sprintf(rt, toStr(rt, values[1]), values, 2)
end

local function numeric(f: (number) -> number): (any, { any }) -> any
	return function(rt, args)
		return f(toNum(eval(rt, args[1])))
	end
end
BUILTIN.sin = numeric(math.sin)
BUILTIN.cos = numeric(math.cos)
BUILTIN.exp = numeric(math.exp)
BUILTIN.log = numeric(math.log)
BUILTIN.sqrt = numeric(math.sqrt)
BUILTIN.int = numeric(trunc)
BUILTIN.atan2 = function(rt, args)
	return math.atan2(toNum(eval(rt, args[1])), toNum(eval(rt, args[2])))
end
BUILTIN.rand = function()
	return math.random()
end
-- The sequence restarts from seed 1 every run, as awk's does, so rand() without
-- srand() repeats between runs. srand() returns the seed it replaced.
BUILTIN.srand = function(rt, args)
	local previous = rt.seed
	rt.seed = if args[1] then toNum(eval(rt, args[1])) else os.time()
	math.randomseed(trunc(rt.seed))
	return previous
end
BUILTIN.tolower = function(rt, args)
	return string.lower(toStr(rt, eval(rt, args[1])))
end
BUILTIN.toupper = function(rt, args)
	return string.upper(toStr(rt, eval(rt, args[1])))
end
BUILTIN.close = function(rt, args)
	local name = toStr(rt, eval(rt, args[1]))
	local found = false
	if rt.readers[name] then
		rt.readers[name] = nil
		found = true
	end
	if rt.files[name] then
		flushFile(rt, name)
		found = true
	end
	return if found then 0 else -1
end
BUILTIN.fflush = function(rt, args)
	if args[1] then
		eval(rt, args[1])
	end
	return 0
end

EVAL.builtin = function(rt, node)
	return BUILTIN[node.name](rt, node.args)
end

-- Statements
-- break, continue and return come back as a string; next, nextfile and exit are
-- thrown, since they leave from inside a function call as readily as a block.

EXEC.nop = function()
	return nil
end
EXEC.block = function(rt, node)
	for _, statement in ipairs(node.body) do
		local signal = exec(rt, statement)
		if signal then
			return signal
		end
	end
	return nil
end
EXEC.expr = function(rt, node)
	eval(rt, node.e)
	return nil
end
EXEC["if"] = function(rt, node)
	if toBool(eval(rt, node.c)) then
		return exec(rt, node.a)
	elseif node.b then
		return exec(rt, node.b)
	end
	return nil
end
EXEC["while"] = function(rt, node)
	while toBool(eval(rt, node.c)) do
		local signal = exec(rt, node.body)
		if signal == "break" then
			break
		elseif signal == "return" then
			return signal
		end
	end
	return nil
end
EXEC["do"] = function(rt, node)
	repeat
		local signal = exec(rt, node.body)
		if signal == "break" then
			break
		elseif signal == "return" then
			return signal
		end
	until not toBool(eval(rt, node.c))
	return nil
end
EXEC["for"] = function(rt, node)
	if node.init then
		eval(rt, node.init)
	end
	while node.c == nil or toBool(eval(rt, node.c)) do
		local signal = exec(rt, node.body)
		if signal == "break" then
			break
		elseif signal == "return" then
			return signal
		end
		if node.step then
			eval(rt, node.step)
		end
	end
	return nil
end
EXEC.forin = function(rt, node)
	local array = getArray(rt, node.array)
	-- A snapshot, so the body can add or delete; a key deleted before its turn
	-- is skipped rather than visited as a ghost.
	for _, key in ipairs(table.clone(array.keys)) do
		if key and array.map[key] ~= nil then
			assignTo(rt, node.var, key)
			local signal = exec(rt, node.body)
			if signal == "break" then
				break
			elseif signal == "return" then
				return signal
			end
		end
	end
	return nil
end
EXEC.print = function(rt, node)
	local text
	if #node.args == 0 then
		text = recordText(rt)
	else
		local parts = table.create(#node.args)
		for i, arg in ipairs(node.args) do
			parts[i] = outStr(rt, eval(rt, arg))
		end
		text = table.concat(parts, toStr(rt, rt.G.OFS))
	end
	send(rt, node, text .. toStr(rt, rt.G.ORS))
	return nil
end
EXEC.printf = function(rt, node)
	local values = table.create(#node.args)
	for i, arg in ipairs(node.args) do
		values[i] = eval(rt, arg)
	end
	send(rt, node, sprintf(rt, toStr(rt, values[1]), values, 2))
	return nil
end
EXEC.delete = function(rt, node)
	local array = getArray(rt, node.array)
	if node.subs then
		adelete(array, subscript(rt, node.subs))
	else
		aclear(array)
	end
	return nil
end
EXEC.next = function()
	error(NEXT, 0)
end
EXEC.nextfile = function()
	error(NEXTFILE, 0)
end
EXEC.exit = function(rt, node)
	if node.e then
		rt.exitCode = trunc(toNum(eval(rt, node.e))) % 256
	end
	error(EXIT, 0)
end
EXEC["return"] = function(rt, node)
	rt.returnValue = if node.e then eval(rt, node.e) else UNINIT
	return "return"
end
EXEC["break"] = function()
	return "break"
end
EXEC["continue"] = function()
	return "continue"
end

-- Running

local function runAction(rt: any, body: any): boolean
	local ok, err = pcall(exec, rt, body)
	rt.frame, rt.depth = nil, 0
	if ok then
		return false
	elseif err == EXIT then
		return true
	elseif err == NEXT or err == NEXTFILE then
		fatal(err.signal .. " cannot be used in a BEGIN or END action")
	end
	error(err, 0)
end

local function recordRules(rt: any, rules: { any })
	for index, rule in ipairs(rules) do
		local selected
		if not rule.pattern then
			selected = true
		elseif not rule.to then
			selected = toBool(eval(rt, rule.pattern))
		elseif rt.active[index] then
			if toBool(eval(rt, rule.to)) then
				rt.active[index] = nil
			end
			selected = true
		elseif toBool(eval(rt, rule.pattern)) then
			-- A range opens and can close on the same record.
			if not toBool(eval(rt, rule.to)) then
				rt.active[index] = true
			end
			selected = true
		end
		if selected then
			if rule.body then
				exec(rt, rule.body)
			else
				local text = recordText(rt) .. toStr(rt, rt.G.ORS)
				emit(rt, text)
				rt.out[#rt.out + 1] = text
			end
		end
	end
end

-- True when the program exited from inside the main loop.
local function mainLoop(rt: any, rules: { any }): boolean
	while true do
		local text, err = nextMainRecord(rt)
		if text == nil then
			if err then
				fatal(err)
			end
			return false
		end
		rt.G.NR = toNum(rt.G.NR) + 1
		rt.G.FNR = toNum(rt.G.FNR) + 1
		setRecord(rt, text)
		tick(rt)
		local ok, signal = pcall(recordRules, rt, rules)
		rt.frame, rt.depth = nil, 0
		if not ok then
			if signal == EXIT then
				return true
			elseif signal == NEXTFILE then
				rt.current = nil
			elseif signal ~= NEXT then
				error(signal, 0)
			end
		end
	end
end

local function drive(rt: any, program: any, opts: any)
	if opts.fs then
		rt.G.FS = unescape(opts.fs)
	end
	for _, assignment in ipairs(opts.assigns or {}) do
		local name, raw = assignment:match("^([%a_][%w_]*)=(.*)$")
		if not name then
			fatal(string.format("-v needs name=value, got `%s'", assignment))
		end
		assignVariable(rt, name, raw)
	end
	local exited = false
	for _, body in ipairs(program.begins) do
		if runAction(rt, body) then
			exited = true
			break
		end
	end
	-- A program that is only BEGIN reads no input at all.
	if not exited and (#program.rules > 0 or #program.ends > 0) then
		mainLoop(rt, program.rules)
	end
	for _, body in ipairs(program.ends) do
		if runAction(rt, body) then
			break
		end
	end
end

local function syntaxMessage(err: any, src: string): string
	if type(err) ~= "table" or not err.syntax then
		return "awk: internal error: " .. tostring(err) .. "\n"
	end
	local tok = err.tok or { line = 1, col = 1 }
	local lines = (src .. "\n"):split("\n")
	local text = lines[tok.line] or ""
	local caret = text:sub(1, math.max(tok.col - 1, 0)):gsub("[^\t]", " ")
	-- A refusal, or a call to a function nobody defined, parsed fine.
	local label = if err.code == 1 then "syntax error: " else ""
	return string.format("awk: line %d: %s%s\n%s\n%s^\n", tok.line, label, err.syntax, text, caret)
end

export type RunOptions = {
	program: string,
	fs: string?,
	assigns: { string }?,
	operands: { string }?,
	stdin: string?,
	environ: { [string]: string }?,
	read: (string) -> (string?, string?),
	write: (string, string, boolean) -> string?,
	breathe: (() -> ())?,
}

-- Returns stdout, stderr and the exit status. A syntax error runs nothing; a
-- runtime error keeps whatever was printed before it, as awk does.
function Awk.run(opts: RunOptions): (string, string, number)
	local parsed, program, warnings = pcall(parse, opts.program)
	if not parsed then
		return "", syntaxMessage(program, opts.program), if type(program) == "table" and program.code then program.code else 2
	end

	local G: { [string]: any } = {
		FS = " ", OFS = " ", ORS = "\n", RS = "\n", NR = 0, FNR = 0, FILENAME = "",
		SUBSEP = "\028", RSTART = 0, RLENGTH = -1, CONVFMT = "%.6g", OFMT = "%.6g",
	}
	local environ = newArray()
	local names: { string } = {}
	for name in pairs(opts.environ or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		aset(environ, name, strnum((opts.environ :: any)[name]))
	end
	G.ENVIRON = environ
	local argv = newArray()
	aset(argv, "0", "awk")
	local operands = opts.operands or {}
	for i, operand in ipairs(operands) do
		aset(argv, tostring(i), strnum(operand))
	end
	G.ARGV = argv
	G.ARGC = #operands + 1

	local rt = {
		G = G, functions = program.functions, frame = nil, depth = 0,
		record = "", fields = nil, nf = 0, dirty = false, recordValue = nil,
		recordFS = " ", paragraph = false,
		out = {}, err = {}, bytes = 0, files = {}, fileOrder = {}, readers = {},
		host = opts, stdin = opts.stdin, current = nil, argIndex = 1,
		usedFile = false, stdinTaken = false, active = {},
		steps = 0, started = os.clock(), breathe = opts.breathe or function() end,
		regexes = {}, regexCount = 0, formats = {},
		exitCode = 0, returnValue = nil, seed = 1, writeFailed = false,
	}
	for _, warning in ipairs(warnings) do
		rt.err[#rt.err + 1] = "awk: " .. warning .. "\n"
	end
	math.randomseed(1)

	local ok, err = pcall(drive, rt, program, opts)
	local code = rt.exitCode
	if not ok then
		local message
		if type(err) == "table" and err.awk then
			message = err.awk
		elseif Regex.isBudget(err) then
			message = "a regex ran past its step budget; simplify the pattern"
		else
			message = "internal error: " .. tostring(err)
		end
		rt.err[#rt.err + 1] = "awk: " .. message .. "\n"
		code = 2
	end
	for _, name in ipairs(rt.fileOrder) do
		if rt.files[name] then
			flushFile(rt, name)
		end
	end
	if rt.writeFailed then
		code = 2
	end
	return table.concat(rt.out), table.concat(rt.err), code
end

-- Self-test
-- The engine needs no DataModel, so the core is pinned here as plain rows. The
-- breadth lives in tests/awk-cases.mjs, where every vector is checked against a
-- real gawk; these are the ones worth failing /selftest over in Studio.
function Awk.selfTest(): (boolean, string?)
	local files = { data = "b 2\na 1\nb 3\n" }
	local cases: { { program: string, input: string?, want: string, code: number?, fs: string? } } = {
		{ program = "{ print $2 }", input = "a b c\nd e f\n", want = "b\ne\n" },
		{ program = "{ s += $2 } END { print s, NR }", input = "x 1\ny 2.5\n", want = "3.5 2\n" },
		{ program = "!seen[$0]++", input = "a\nb\na\nc\nb\n", want = "a\nb\nc\n" },
		{ program = "NR==2, NR==3", input = "1\n2\n3\n4\n", want = "2\n3\n" },
		{ program = "/b/ { n++ } END { print n+0 }", input = "abc\nxyz\nb\n", want = "2\n" },
		{ program = "{ print $1 }", fs = ":", input = "root:x:0\n", want = "root\n" },
		{ program = "BEGIN { print 1 \" \" -1 }", want = "1-1\n" },
		{ program = "BEGIN { printf \"%5.2f|%-3d|%c|%x\\n\", 3.14159, 7, 65, 255 }",
			want = " 3.14|7  |A|ff\n" },
		{ program = "BEGIN { s = \"abc\"; n = gsub(/b*/, \"-\", s); print n, s }", want = "3 -a-c-\n" },
		{ program = "{ $2 = \"X\"; print; print NF }", input = "a b c\n", want = "a X c\n3\n" },
		{ program = "{ $5 = \"e\"; print }", input = "a b\n", want = "a b   e\n" },
		{ program = "{ print ($1 == 10), ($1 < 9) }", input = "10.0\n", want = "1 0\n" },
		{ program = "BEGIN { print (\"10\" < \"9\"), (10 < 9) }", want = "1 0\n" },
		{ program = "BEGIN { print substr(\"hello\", 2, 3), index(\"hello\", \"ll\"), length(\"hi\") }",
			want = "ell 3 2\n" },
		{ program = "BEGIN { n = split(\"a:b:c\", p, \":\"); print n, p[3] }", want = "3 c\n" },
		{ program = "function f(n) { return n < 2 ? n : f(n-1) + f(n-2) } BEGIN { print f(15) }",
			want = "610\n" },
		{ program = "function fill(a) { a[1] = \"x\" } BEGIN { fill(t); print t[1] }", want = "x\n" },
		{ program = "{ c[$1] += $2 } END { for (k in c) print k, c[k] }", input = files.data,
			want = "b 5\na 1\n" },
		{ program = "BEGIN { while ((getline line < \"data\") > 0) n++; print n }", want = "3\n" },
		{ program = "BEGIN { exit 3 } END { print \"end\" }", want = "end\n", code = 3 },
		{ program = "BEGIN { RS = \"\" } { print NR \": \" $1 \"/\" $NF }", input = "a b\nc\n\n\nd\n",
			want = "1: a/c\n2: d/d\n" },
		{ program = "BEGIN { print 2^53, 0.1 + 0.2, 1e6, 1/3 }", want = "9007199254740992 0.3 1000000 0.333333\n" },
		{ program = "{ print } { print 1/0 }", input = "kept\n", want = "kept\n", code = 2 },
		{ program = "BEGIN { printf \"%d %d\\n\", \"3abc\", -3.9 }", want = "3 -3\n" },
		{ program = "{ print", want = "", code = 1 },
		{ program = "BEGIN { system(\"ls\") }", want = "", code = 2 },
	}
	for index, case in ipairs(cases) do
		local out, err, code = Awk.run({
			program = case.program, fs = case.fs, stdin = case.input, operands = {},
			read = function(path) return files[path], "no such file" end,
			write = function() return nil end,
		})
		if out ~= case.want or code ~= (case.code or 0) then
			return false, string.format("awk case %d (%s): expected %q exit %d, got %q exit %d %s",
				index, case.program, case.want, case.code or 0, out, code, err)
		end
	end
	return true, nil
end

return Awk
