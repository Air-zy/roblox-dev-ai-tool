--!strict
-- The sed engine: addresses, s///, transliteration, the text commands.
--
-- Pure text, no DataModel, no terminal. HANDLERS.sed in Shell reads the files
-- and writes them back; everything about what sed MEANS is here.
--
-- ESCAPES is shared with tr, which is sed's sibling and wants the same table.
local Regex = require(script.Parent:WaitForChild("Regex"))

local ESCAPES: { [string]: string } = {
	n = "\n", t = "\t", r = "\r", f = "\f", v = "\v", a = "\a", b = "\b",
	["\\"] = "\\", ["-"] = "-", ["["] = "[", ["]"] = "]",
}

-- sed
-- As much of sed as has a meaning here: substitution, transliteration, delete,
-- explicit print, quit, line numbering and the three text commands, each with
-- an optional address that is a line number, `$`, a /pattern/, or a range of
-- either. Expressions come from -e (repeatable) or the first operand and run in
-- order against every line, which is what makes `sed -e '/^%-%-/d' -e 's/a/b/'`
-- mean what it does in sed.
--
-- Reading an arbitrary window of a script is the reason addresses exist here at
-- all: it was otherwise `head -N | tail -M` and a subtraction the caller had to
-- get right every time, and getting it wrong returns a plausible block from the
-- wrong part of the file.
type SedAddress = number | string | { pattern: string }
type SedCommand = { from: SedAddress?, to: SedAddress?, name: string, args: any }

-- One endpoint of an address, starting at `at`. Returns the endpoint and the
-- position after it, or nil when there is no address here at all.
local function parseAddressPart(expr: string, at: number, ere: boolean): (SedAddress?, number)
	local c = expr:sub(at, at)
	if c == "$" then
		return "$", at + 1
	end
	if c == "/" then
		local i = at + 1
		local buf: { string } = {}
		while i <= #expr do
			local ch = expr:sub(i, i)
			if ch == "\\" and expr:sub(i + 1, i + 1) == "/" then
				buf[#buf + 1] = "/"
				i += 2
			elseif ch == "/" then
				-- Compiled here rather than matched as text later: an address is a
				-- real pattern in sed, in the same dialect as the s/// it sits
				-- beside, and compiling once beats compiling per line.
				local program = Regex.compile(table.concat(buf), { ere = ere })
				if not program then
					return nil, at
				end
				return { program = program }, i + 1
			else
				buf[#buf + 1] = ch
				i += 1
			end
		end
		return nil, at
	end
	local digits = expr:match("^%d+", at)
	if digits then
		return tonumber(digits), at + #digits
	end
	return nil, at
end

-- sed's replacement syntax, which is not Lua's: `\1`-`\9` are the groups, `&` is
-- the whole match, and `\&` is a literal ampersand. Lua's `%1` went with the Lua
-- patterns it belonged to.
local function expandReplacement(replacement: string, whole: string, caps: { string }): string
	local buf: { string } = {}
	local i = 1
	while i <= #replacement do
		local c = replacement:sub(i, i)
		if c == "\\" and i < #replacement then
			local following = replacement:sub(i + 1, i + 1)
			local group = tonumber(following)
			if group and group >= 1 then
				-- An unmatched group is the empty string, as it is in sed, not an
				-- error, and not the literal text "\1".
				buf[#buf + 1] = caps[group] or ""
			else
				buf[#buf + 1] = ESCAPES[following] or following
			end
			i += 2
		elseif c == "&" then
			buf[#buf + 1] = whole
			i += 1
		else
			buf[#buf + 1] = c
			i += 1
		end
	end
	return table.concat(buf)
end

-- One s/// pass over a line. Written out rather than handed to gsub because the
-- engine is ours now: gsub only speaks Lua patterns.
-- Returns the new text and HOW MANY replacements happened: `p` needs the count,
-- since it prints only when the line actually changed.
local function substitute(program: any, text: string, replacement: string,
	global: boolean, occurrence: number): (string, number)
	local out: { string } = {}
	local at = 1
	local seen, changed = 0, 0
	while at <= #text + 1 do
		local start, finish, caps = program:find(text, at)
		if not start then
			break
		end
		seen += 1
		-- `s/x/y/2` replaces the second match and no other; `s/x/y/2g` replaces
		-- from the second onwards. Everything before the Nth is copied through.
		local replace = seen >= occurrence and (global or seen == occurrence)
		out[#out + 1] = text:sub(at, start - 1)
		if replace then
			out[#out + 1] = expandReplacement(replacement, text:sub(start, finish), caps)
			changed += 1
		else
			out[#out + 1] = text:sub(start, finish)
		end
		-- An empty match consumes nothing, so it has to be stepped past by hand or
		-- `s/x*/-/g` never terminates.
		if (finish :: number) < start then
			out[#out + 1] = text:sub(start, start)
			at = start + 1
		else
			at = (finish :: number) + 1
		end
		if replace and not global then
			break
		end
	end
	out[#out + 1] = text:sub(at)
	return table.concat(out), changed
end

-- Split `expr` into its address (if any) and the command that follows.
local function parseAddress(expr: string, ere: boolean): (SedAddress?, SedAddress?, string)
	local from, at = parseAddressPart(expr, 1, ere)
	if not from then
		return nil, nil, expr
	end
	if expr:sub(at, at) == "," then
		local to, after = parseAddressPart(expr, at + 1, ere)
		if to then
			return from, to, expr:sub(after)
		end
	end
	return from, from, expr:sub(at)
end

-- Split `s/a/b/flags` (or y///) on its delimiter.
--
-- A backslash is only consumed when it escapes the DELIMITER. Every other one is
-- data and has to survive intact: `\d` and `\+` mean something to the regex,
-- `\1` and `\&` to the replacement. This used to strip them all, a leftover
-- from when the replacement was Lua's `%1` and a backslash could only ever be
-- protecting a slash, so `s/(al)(pha)/\2\1/` arrived as the literal text "21"
-- and substituted that.
local function splitDelimited(rest: string, delim: string): { string }
	local parts: { string } = {}
	local current: { string } = {}
	local i = 1
	while i <= #rest do
		local c = rest:sub(i, i)
		if c == "\\" then
			local following = rest:sub(i + 1, i + 1)
			if following == delim then
				current[#current + 1] = following
			else
				current[#current + 1] = c
				current[#current + 1] = following
			end
			i += 2
		elseif c == delim then
			parts[#parts + 1] = table.concat(current)
			current = {}
			i += 1
		else
			current[#current + 1] = c
			i += 1
		end
	end
	parts[#parts + 1] = table.concat(current)
	return parts
end


-- Parse one expression into a command. `extended` is -E/-r, so sed is BRE by
-- default and ERE on request, the same two dialects grep has, chosen the same
-- way. Patterns and addresses are compiled HERE rather than matched as text
-- later, so a bad one is refused before a single line runs.
local function parseSedCommand(expr: string, extended: boolean): (SedCommand?, string?)
	local from, to, body = parseAddress((expr:gsub("^%s+", "")), extended)
	body = body:gsub("^%s+", "")
	-- A reversed numeric range selects nothing. sed would print nothing and call
	-- it a success, which is indistinguishable from "those lines were empty"
	-- and `10,2p` is always a typo for `2,10p`.
	if type(from) == "number" and type(to) == "number" and (from :: number) > (to :: number) then
		return nil, string.format("empty range: line %d comes after line %d", from, to)
	end
	local name = body:sub(1, 1)
	if name == "" then
		if from then
			-- `sed -n '10,40'` with no command: printing is what was meant, and
			-- guessing beats an error nobody can act on.
			return { from = from, to = to, name = "p", args = nil }, nil
		end
		return nil, "empty expression"
	end

	if name == "s" or name == "y" then
		local delim = body:sub(2, 2)
		if delim == "" or delim:match("%s") or delim:match("%w") then
			return nil, string.format("invalid delimiter after %s", name)
		end
		local parts = splitDelimited(body:sub(3), delim)
		if #parts < 3 then
			return nil, string.format("malformed expression, expected %s/old/new/%s",
				name, name == "s" and "[g]" or "")
		end
		local pattern = parts[1]
		local mod = parts[3] or ""
		local args: any = { replacement = parts[2], mod = mod }
		if name == "s" then
			-- Suffix flags are VALIDATED and then actually READ. `p` was parsed
			-- and dropped, so `sed -n 's/x/y/p'`, the standard "print only the
			-- changed lines" idiom, printed nothing at all, and `s/x/y/qqqzzz`
			-- was accepted in silence. Both are the declared-but-never-read shape
			-- this file keeps finding.
			local occurrence = 1
			local digits = mod:match("%d+")
			if digits then
				occurrence = tonumber(digits) :: number
				if occurrence < 1 then
					return nil, "the number after s/// is which occurrence to replace, counting from 1"
				end
			end
			for char in mod:gmatch("%D") do
				if not ("gpiI"):find(char, 1, true) then
					return nil, string.format("unknown flag %q after s/// — g (every match), " ..
						"p (print when changed), i (ignore case), or a number (which occurrence)",
						char)
				end
			end
			args.global = mod:find("g", 1, true) ~= nil
			args.print = mod:find("p", 1, true) ~= nil
			args.occurrence = occurrence
			-- sed is BRE by default and ERE under -E/-r, exactly as grep is.
			local program, compileErr = Regex.compile(pattern,
				{ ere = extended, ignoreCase = mod:find("[iI]") ~= nil })
			if not program then
				return nil, compileErr
			end
			args.program = program
		else
			args.pattern = pattern
		end
		return { from = from, to = to, name = name, args = args }, nil
	end

	if name == "d" or name == "p" or name == "q" or name == "=" then
		return { from = from, to = to, name = name, args = nil }, nil
	end

	if name == "a" or name == "i" or name == "c" then
		-- `a text`, and also GNU's `a\text`. The rest of the expression is data.
		local text = body:sub(2):gsub("^\\", ""):gsub("^%s+", "")
		return { from = from, to = to, name = name, args = text }, nil
	end

	return nil, string.format("unsupported command %q — sed here does s/// and y/// " ..
		"substitution, d (delete), p (print), q (quit), = (line number) and " ..
		"a/i/c (append, insert, change), each with an optional address", name)
end

-- Does this command's address select line `index`? `active` carries the state of
-- a /start/,/end/ range across lines, which is the only part of matching that
-- cannot be decided from one line alone.
local function sedSelects(command: SedCommand, index: number, line: string,
	total: number, active: { [number]: boolean }, slot: number): boolean
	local function endpoint(address: SedAddress?): boolean?
		if address == nil then
			return nil
		end
		if address == "$" then
			return index == total
		end
		if type(address) == "number" then
			return index == address
		end
		return (address :: any).program:find(line) ~= nil
	end

	if command.from == nil then
		return true
	end
	-- A single address, or a numeric range, both answer from this line alone.
	if command.from == command.to then
		return endpoint(command.from) == true
	end
	if type(command.from) == "number" and type(command.to) == "number" then
		return index >= (command.from :: number) and index <= (command.to :: number)
	end
	-- A pattern range: on until the closing address matches.
	if active[slot] then
		if endpoint(command.to) == true then
			active[slot] = false
		end
		return true
	end
	if endpoint(command.from) == true then
		-- A one-line range is legal: /a/,/a/ ends where it starts only if the
		-- closing address is checked from the NEXT line, which is what sed does.
		active[slot] = true
		return true
	end
	return false
end


return {
	parseSedCommand = parseSedCommand,
	sedSelects = sedSelects,
	substitute = substitute,
	ESCAPES = ESCAPES,
}
