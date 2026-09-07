--!optimize 2
-- The shell's lexer and grammar, extracted from Shell's token/statement/loop
-- parsers. Words retain their original spelling until the command executes.
-- Parsing an entire list before executing it prevents a missing fi/done/brace
-- from applying half a command. Expansion never produces grammar tokens.
local Syntax = {}

local function bad(message: string): never
	error(message, 0)
end

-- Skip a substitution while lexing a word. Quotes inside $(...) belong to the
-- inner command, not the surrounding word. Recursing handles "$(echo "$(pwd)")".
local scanWord
local function substitutionEnd(text: string, at: number, ending: string, depth: number): number
	if depth > 64 then bad("shell syntax nested more than 64 deep") end
	local i, level = at, 1
	while i <= #text do
		local c = text:sub(i, i)
		if c == "\\" then i += 2
		elseif ending == "`" and c == "`" then return i + 1
		elseif c == "'" then
			local close = text:find("'", i + 1, true)
			if not close then bad("unterminated ' quote") end
			i = close + 1
		elseif c == '"' then
			i += 1
			while i <= #text and text:sub(i, i) ~= '"' do
				if text:sub(i, i) == "\\" then i += 2
				elseif text:sub(i, i + 1) == "$(" then i = substitutionEnd(text, i + 2, ")", depth + 1)
				elseif text:sub(i, i) == "`" then i = substitutionEnd(text, i + 1, "`", depth + 1)
				else i += 1 end
			end
			if i > #text then bad('unterminated " quote') end
			i += 1
		elseif c == "`" then i = substitutionEnd(text, i + 1, "`", depth + 1)
		elseif c == "(" and ending == ")" then level += 1; i += 1
		elseif c == ")" and ending == ")" then
			level -= 1
			if level == 0 then return i + 1 end
			i += 1
		elseif c == "}" and ending == "}" then return i + 1
		elseif text:sub(i, i + 1) == "${" then i = substitutionEnd(text, i + 2, "}", depth + 1)
		else i += 1 end
	end
	bad("unclosed `" .. (ending == ")" and "$(" or ending == "}" and "${" or "`") .. "`")
end
Syntax.substitutionEnd = substitutionEnd

-- Quote removal only, used for reserved words and heredoc delimiters. Parameter
-- and command substitution are deliberately absent at this stage.
function Syntax.literal(raw: string): string
	local out, quote, i = {}, nil, 1
	while i <= #raw do
		local c = raw:sub(i, i)
		if c == "\\" and quote ~= "'" then
			local nextChar = raw:sub(i + 1, i + 1)
			if quote == nil or nextChar:find('[\\$`"]') or nextChar == "\n" then
				if nextChar ~= "\n" then out[#out + 1] = nextChar end
				i += 2
			else out[#out + 1] = c; i += 1 end
		elseif c == quote then quote = nil; i += 1
		elseif not quote and (c == '"' or c == "'") then quote = c; i += 1
		else out[#out + 1] = c; i += 1 end
	end
	return table.concat(out)
end

function scanWord(text: string, start: number): number
	local i, quote = start, nil
	while i <= #text do
		local c = text:sub(i, i)
		if c == "\\" and quote ~= "'" then
			if i == #text then bad("trailing backslash") end
			i += 2
		elseif quote ~= "'" and text:sub(i, i + 1) == "$(" then
			i = substitutionEnd(text, i + 2, ")", 1)
		elseif quote ~= "'" and text:sub(i, i + 1) == "${" then
			i = substitutionEnd(text, i + 2, "}", 1)
		elseif quote ~= "'" and c == "`" then i = substitutionEnd(text, i + 1, "`", 1)
		elseif quote then if c == quote then quote = nil end; i += 1
		elseif c == "'" or c == '"' then quote = c; i += 1
		elseif c:match("[%s;|&<>()]") then break
		else i += 1 end
	end
	if quote then bad("unterminated " .. quote .. " quote") end
	return i
end

function Syntax.lex(text: string): { any }
	if #text > 1000000 then bad("shell input exceeds 1000000 bytes") end
	text = text:gsub("\r\n", "\n")
	local tokens, pending, i = {}, {}, 1
	local expectDelimiter = nil
	while i <= #text do
		local c = text:sub(i, i)
		if c == "\\" and text:sub(i + 1, i + 1) == "\n" then i += 2
		elseif c == "#" then
			i = text:find("\n", i, true) or (#text + 1)
		elseif c == "\n" then
			tokens[#tokens + 1] = { raw = ";", op = true, newline = true }
			i += 1
			for _, doc in ipairs(pending) do
				local lines, found = {}, false
				while i <= #text do
					local finish = text:find("\n", i, true) or (#text + 1)
					local line = text:sub(i, finish - 1)
					if doc.strip then line = line:gsub("^\t+", "") end
					i = finish + 1
					if line == doc.delimiter then found = true; break end
					lines[#lines + 1] = line .. (finish <= #text and "\n" or "")
				end
				if not found then bad("heredoc: missing delimiter " .. tostring(doc.delimiter)) end
				doc.body = table.concat(lines)
			end
			pending = {}
		elseif c:match("%s") then i += 1
		else
			local tail = text:sub(i)
			local op = tail:match("^([012]?<<%-)") or tail:match("^([012]?<<)")
				or tail:match("^([012&]?>>)") or tail:match("^([012]?>&[012%-])")
				or tail:match("^([012&]?>)") or tail:match("^([012]?<)")
				or tail:match("^(&&)") or tail:match("^(||)") or tail:match("^(;;)")
				or tail:match("^([;|&()])")
			local token
			if op then
				token = { raw = op, op = true }
				i += #op
			else
				local finish = scanWord(text, i)
				local raw = text:sub(i, finish - 1)
				token = { raw = raw, quoted = raw:find("['\"\\]") ~= nil }
				i = finish
			end
			tokens[#tokens + 1] = token
			if expectDelimiter then
				if token.op then bad("heredoc: expected a delimiter") end
				expectDelimiter.delimiter = Syntax.literal(token.raw)
				expectDelimiter.expand = not token.quoted
				expectDelimiter = nil
			elseif op and op:find("<<", 1, true) then
				token.strip = op:sub(-1) == "-"
				pending[#pending + 1] = token
				expectDelimiter = token
			end
		end
	end
	if expectDelimiter or #pending > 0 then bad("heredoc: missing body or delimiter") end
	return tokens
end

-- Compatibility entry for the existing tokenizer regression vectors.
function Syntax.tokenize(text: string): ({ string }?, string?, { [number]: boolean })
	local ok, tokens = pcall(Syntax.lex, text)
	if not ok then return nil, tostring(tokens), {} end
	local argv, quoted = {}, {}
	for i, token in ipairs(tokens) do argv[i] = Syntax.literal(token.raw); quoted[i] = token.quoted end
	return argv, nil, quoted
end

function Syntax.parse(text: string): any
	local tokens, at, depth = Syntax.lex(text), 1, 0
	local parseList, parseCommand
	local function is(word: string): boolean
		local token = tokens[at]
		return token ~= nil and token.raw == word and not token.quoted
	end
	local function expect(word: string)
		if not is(word) then bad("expected `" .. word .. "`, got " .. (tokens[at] and tokens[at].raw or "end of input")) end
		at += 1
	end
	local function newlines()
		while tokens[at] and tokens[at].newline do at += 1 end
	end
	local function word(): any
		local token = tokens[at]
		if not token or token.op then bad("expected a word") end
		at += 1
		return token
	end
	local function nonempty(list: any, label: string): any
		if #list == 0 then bad(label .. ": expected a command (use : for an empty body)") end
		return list
	end
	local function redirects(into: { any }): boolean
		local token = tokens[at]
		if not token or not token.op or not token.raw:find("[<>]") then return false end
		at += 1
		if token.raw:find(">&", 1, true) then into[#into + 1] = { op = token.raw }
		else into[#into + 1] = { op = token.raw, word = word(), body = token.body, expand = token.expand } end
		return true
	end
	local closing = { ["then"] = true, ["elif"] = true, ["else"] = true, ["fi"] = true,
		["do"] = true, ["done"] = true, ["esac"] = true, ["}"] = true, [")"] = true }
	function parseCommand(): any
		depth += 1
		if depth > 64 then bad("shell syntax nested more than 64 deep") end
		local node = { kind = "simple", words = {}, redirects = {} }
		if is("if") then
			node.kind, node.branches = "if", {}
			at += 1
			repeat
				local condition = nonempty(parseList({ ["then"] = true }), "if condition")
				expect("then")
				local body = parseList({ ["elif"] = true, ["else"] = true, ["fi"] = true })
				node.branches[#node.branches + 1] = { condition = condition, body = nonempty(body, "if body") }
				if not is("elif") then break end
				at += 1
			until false
			if is("else") then at += 1; node.otherwise = nonempty(parseList({ ["fi"] = true }), "else body") end
			if not is("fi") then bad("if: missing `fi`") end
			expect("fi")
		elseif is("for") then
			node.kind = "for"; at += 1; node.name = word().raw
			if not node.name:match("^[%a_][%w_]*$") then bad("for: invalid variable name") end
			if is("in") then
				at += 1; node.items = {}
				while tokens[at] and not is(";") do node.items[#node.items + 1] = word() end
			end
			if not is(";") then bad("for: expected `do` after the word list") end
			while is(";") do at += 1 end
			expect("do"); node.body = nonempty(parseList({ ["done"] = true }), "for body")
			if not is("done") then bad("for: missing `done`") end
			expect("done")
		elseif is("while") or is("until") then
			node.kind = tokens[at].raw; at += 1
			node.condition = nonempty(parseList({ ["do"] = true }), node.kind .. " condition"); expect("do")
			node.body = nonempty(parseList({ ["done"] = true }), node.kind .. " body")
			if not is("done") then bad(node.kind .. ": missing `done`") end
			expect("done")
		elseif is("case") then
			node.kind, node.arms = "case", {}; at += 1; node.word = word()
			newlines(); expect("in"); newlines()
			while tokens[at] and not is("esac") do
				if is("(") then at += 1 end
				local patterns = { word() }
				while is("|") do at += 1; patterns[#patterns + 1] = word() end
				expect(")")
				local body = parseList({ [";;"] = true, ["esac"] = true })
				node.arms[#node.arms + 1] = { patterns = patterns, body = body }
				if is(";;") then at += 1; newlines() else break end
			end
			expect("esac")
		elseif is("{") or is("(") then
			local close = is("{") and "}" or ")"
			node.kind = is("{") and "group" or "subshell"; at += 1
			node.body = nonempty(parseList({ [close] = true }), "group"); expect(close)
		elseif is("function") or (tokens[at] and tokens[at].raw:match("^[%a_][%w_]*$")
			and tokens[at + 1] and tokens[at + 1].raw == "(" and tokens[at + 2] and tokens[at + 2].raw == ")") then
			node.kind = "function"
			if is("function") then at += 1 end
			node.name = word().raw
			if not node.name:match("^[%a_][%w_]*$") then bad("invalid function name") end
			if is("(") then at += 1; expect(")") end
			newlines()
			if not (is("{") or is("(")) then bad("function: expected a grouped body") end
			node.body = parseCommand()
		else
			local first = tokens[at]
			if first and closing[first.raw] and not first.quoted then bad("unexpected `" .. first.raw .. "`") end
			while tokens[at] do
				if redirects(node.redirects) then continue end
				if tokens[at].op then break end
				node.words[#node.words + 1] = word()
			end
			if #node.words == 0 and #node.redirects == 0 then bad("expected a command") end
		end
		while redirects(node.redirects) do end
		depth -= 1
		return node
	end
	function parseList(stops: { [string]: boolean }): { any }
		local list, joiner = {}, ";"
		while is(";") do at += 1 end
		while tokens[at] and not (stops[tokens[at].raw] and not tokens[at].quoted) do
			local entry = { joiner = joiner, stages = {}, negate = false }
			while is("!") do entry.negate = not entry.negate; at += 1 end
			entry.stages[1] = parseCommand()
			while is("|") do at += 1; newlines(); entry.stages[#entry.stages + 1] = parseCommand() end
			list[#list + 1] = entry
			if is("&&") or is("||") then
				joiner = tokens[at].raw; at += 1; newlines()
				if not tokens[at] or stops[tokens[at].raw] then bad("expected a command after " .. joiner) end
			elseif is(";") then
				joiner = ";"; repeat at += 1 until not is(";")
			elseif is("&") then bad("& is not supported — nothing here runs in the background")
			elseif tokens[at] and not (stops[tokens[at].raw] and not tokens[at].quoted) then
				bad("unexpected `" .. tokens[at].raw .. "`, expected a command separator")
			else break end
		end
		return list
	end
	local ast = parseList({})
	if tokens[at] then bad("unexpected `" .. tokens[at].raw .. "`") end
	return ast
end

return Syntax
