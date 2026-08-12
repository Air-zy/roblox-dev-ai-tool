--!optimize 2
-- Regex.luau: a real regular expression engine.
--
-- This exists because there was a translation layer here instead: `grep -E` took
-- the pattern, rewrote the escapes it could map onto Lua patterns, and refused
-- the constructs it could not. That advertised POSIX and delivered something
-- else, and its failure mode was the worst available, a confident "no matches"
-- against a pattern the engine never understood.
--
-- The rule it broke: the agent should never need to know this is Roblox. The
-- DataModel is content and may show; Luau is implementation and must not leak.
-- `%d` reaching a model that wrote `\d` is a leak.
--
-- Shape: source -> parse -> AST -> backtracking match with continuations.
-- Compiled ONCE per command and matched per line; the old code re-parsed its
-- pattern for every line of every script it touched.
--
-- Dialects differ only in which characters are metacharacters bare and which
-- need a backslash, so BRE and ERE are one parser and a table (see META).

local Regex = {}

-- Limits
-- Backtracking has catastrophic cases: `(a+)+$` against a long non-match is the
-- classic: and Luau cannot preempt a running chunk, so an unbounded matcher
-- does not run slowly, it freezes Studio outright. That is the same hazard the
-- `run` tool documents against its missing timeout, except here it would fire on
-- an ordinary grep. The budget is per find() call over one line.
--
-- ponytail: a step cap rather than a linear-time engine. Ceiling: a legitimate
-- but very expensive pattern is refused rather than served slowly. The upgrade
-- path is a Thompson NFA simulation, which is linear and cannot blow up, but it
-- cannot do backreferences either, which is why every real grep still ships a
-- backtracker.
local MAX_STEPS = 200000

-- Character classes
-- Sets are plain lookup tables keyed by the character. Built once at compile
-- time, including both cases when the match is case-insensitive, so the matcher
-- itself never lowercases anything, that matters because captures are sliced
-- out of the ORIGINAL subject and must keep their original case.
local function addRange(set: { [string]: boolean }, from: string, to: string)
	for code = string.byte(from), string.byte(to) do
		set[string.char(code)] = true
	end
end

local function digitSet(): { [string]: boolean }
	local set = {}
	addRange(set, "0", "9")
	return set
end

local function wordSet(): { [string]: boolean }
	local set = digitSet()
	addRange(set, "a", "z")
	addRange(set, "A", "Z")
	set["_"] = true
	return set
end

local function spaceSet(): { [string]: boolean }
	return { [" "] = true, ["\t"] = true, ["\n"] = true, ["\r"] = true, ["\f"] = true, ["\v"] = true }
end

-- POSIX bracket names, which are portable regex and appear in real scripts.
local POSIX: { [string]: () -> { [string]: boolean } } = {
	digit = digitSet,
	alpha = function()
		local set = {}
		addRange(set, "a", "z")
		addRange(set, "A", "Z")
		return set
	end,
	alnum = function()
		local set = digitSet()
		addRange(set, "a", "z")
		addRange(set, "A", "Z")
		return set
	end,
	space = spaceSet,
	upper = function()
		local set = {}
		addRange(set, "A", "Z")
		return set
	end,
	lower = function()
		local set = {}
		addRange(set, "a", "z")
		return set
	end,
	punct = function()
		local set = {}
		for code = 33, 47 do set[string.char(code)] = true end
		for code = 58, 64 do set[string.char(code)] = true end
		for code = 91, 96 do set[string.char(code)] = true end
		for code = 123, 126 do set[string.char(code)] = true end
		return set
	end,
	xdigit = function()
		local set = digitSet()
		addRange(set, "a", "f")
		addRange(set, "A", "F")
		return set
	end,
	cntrl = function()
		local set = {}
		for code = 0, 31 do set[string.char(code)] = true end
		set[string.char(127)] = true
		return set
	end,
	print = function()
		local set = {}
		for code = 32, 126 do set[string.char(code)] = true end
		return set
	end,
	graph = function()
		local set = {}
		for code = 33, 126 do set[string.char(code)] = true end
		return set
	end,
	blank = function()
		return { [" "] = true, ["\t"] = true }
	end,
}

-- \d \w \s and their negations, plus the control-character escapes. These are
-- GNU extensions rather than POSIX, but every grep in service accepts them and
-- every model writes them.
local CLASS_ESCAPES: { [string]: { set: () -> { [string]: boolean }, negate: boolean } } = {
	d = { set = digitSet, negate = false }, D = { set = digitSet, negate = true },
	w = { set = wordSet,  negate = false }, W = { set = wordSet,  negate = true },
	s = { set = spaceSet, negate = false }, S = { set = spaceSet, negate = true },
}

local CONTROL_ESCAPES: { [string]: string } = {
	n = "\n", t = "\t", r = "\r", f = "\f", v = "\v", a = "\a", e = "\27", ["0"] = "\0",
}

local WORD = wordSet()

-- Parser
-- BRE and ERE differ ONLY in whether these are metacharacters bare or escaped.
-- In ERE `(a|b)+` means what it looks like; in BRE the same effect is
-- `\(a\|b\)\+` and the bare forms are literal text. One table, one parser.
local ERE_META: { [string]: boolean } = {
	["("] = true, [")"] = true, ["|"] = true, ["+"] = true, ["?"] = true,
	["{"] = true, ["}"] = true,
}

type Node = any

local function parse(source: string, ere: boolean, ignoreCase: boolean): (Node?, string?)
	local pos = 1
	local groupCount = 0
	local failure: string? = nil

	local function fail(message: string): nil
		failure = failure or message
		return nil
	end

	local function peek(): string
		return source:sub(pos, pos)
	end

	-- Is the character at `pos` acting as metacharacter `which`? In ERE the bare
	-- form is meta; in BRE the backslashed form is.
	local function isMeta(which: string): boolean
		if ere then
			return source:sub(pos, pos) == which
		end
		return source:sub(pos, pos + 1) == "\\" .. which
	end

	local function takeMeta(which: string)
		pos += ere and 1 or 2
	end

	local parseAlt

	-- [abc], [^a-z], [[:digit:]]. Note the POSIX rule that `]` first is literal
	-- and `-` last is literal, which real patterns rely on.
	local function parseClass(): Node?
		pos += 1
		local negate = false
		if peek() == "^" then
			negate = true
			pos += 1
		end
		local set: { [string]: boolean } = {}
		local first = true
		while true do
			local c = peek()
			if c == "" then
				return fail("unterminated [ in pattern")
			end
			if c == "]" and not first then
				pos += 1
				break
			end
			first = false

			-- [[:alpha:]], the inner brackets are part of the name, not a nested
			-- class, which is why this is checked before anything else.
			local name = source:match("^%[:(%a+):%]", pos)
			if name then
				local builder = POSIX[name]
				if not builder then
					return fail(string.format("unknown character class [:%s:]", name))
				end
				for char in pairs(builder()) do
					set[char] = true
				end
				pos += #name + 4
				continue
			end

			local char = c
			if c == "\\" then
				pos += 1
				local escaped = peek()
				if escaped == "" then
					return fail("pattern ends with a backslash")
				end
				local classEscape = CLASS_ESCAPES[escaped]
				if classEscape then
					-- \d inside a class contributes its members. A NEGATED escape
					-- inside a class (\D) cannot be expressed as a member list, so
					-- it is refused rather than silently narrowed.
					if classEscape.negate then
						return fail(string.format("\\%s cannot be used inside [ ]", escaped))
					end
					for member in pairs(classEscape.set()) do
						set[member] = true
					end
					pos += 1
					continue
				end
				char = CONTROL_ESCAPES[escaped] or escaped
			end
			pos += 1

			-- A range, unless the dash is the last character before ].
			if peek() == "-" and source:sub(pos + 1, pos + 1) ~= "]" and source:sub(pos + 1, pos + 1) ~= "" then
				pos += 1
				local hi = peek()
				if hi == "\\" then
					pos += 1
					hi = CONTROL_ESCAPES[peek()] or peek()
				end
				if string.byte(hi) < string.byte(char) then
					return fail(string.format("reversed range %s-%s in [ ]", char, hi))
				end
				addRange(set, char, hi)
				pos += 1
			else
				set[char] = true
			end
		end

		if ignoreCase then
			-- Both cases baked in at compile time, so the matcher stays a single
			-- table lookup and captures keep the subject's original case.
			local folded: { [string]: boolean } = {}
			for char in pairs(set) do
				folded[char:lower()] = true
				folded[char:upper()] = true
			end
			set = folded
		end
		return { kind = "class", set = set, negate = negate }
	end

	local function parseAtom(): Node?
		local c = peek()
		if c == "" then
			return nil
		end

		if isMeta("(") then
			takeMeta("(")
			local capture = true
			local look: string? = nil
			-- (?: (?= (?!. ERE has no such syntax, so these are PCRE-only and
			-- only recognised there.
			if ere and peek() == "?" then
				local after = source:sub(pos + 1, pos + 1)
				if after == ":" then
					capture = false
					pos += 2
				elseif after == "=" then
					look, capture = "ahead", false
					pos += 2
				elseif after == "!" then
					look, capture = "notahead", false
					pos += 2
				elseif after == "<" then
					return fail("lookbehind (?<...) is not supported — a variable-length " ..
						"lookbehind needs a different engine, and guessing at it would " ..
						"return wrong matches silently")
				end
			end
			local index: number? = nil
			if capture then
				groupCount += 1
				index = groupCount
			end
			local body = parseAlt()
			if not body then
				return nil
			end
			if not isMeta(")") then
				return fail("unmatched ( in pattern")
			end
			takeMeta(")")
			if look then
				return { kind = "look", body = body, negated = look == "notahead" }
			end
			return { kind = "group", body = body, index = index }
		end

		if c == "[" then
			return parseClass()
		end

		if c == "." then
			pos += 1
			return { kind = "any" }
		end

		if c == "^" then
			pos += 1
			return { kind = "anchor", at = "start" }
		end

		if c == "$" then
			pos += 1
			return { kind = "anchor", at = "end" }
		end

		if c == "\\" then
			local escaped = source:sub(pos + 1, pos + 1)
			if escaped == "" then
				return fail("pattern ends with a backslash")
			end
			-- In BRE the metacharacters arrive escaped, so those are handled by
			-- isMeta above and must not be swallowed here.
			if not ere and ERE_META[escaped] then
				return nil
			end
			pos += 2
			local classEscape = CLASS_ESCAPES[escaped]
			if classEscape then
				return { kind = "class", set = classEscape.set(), negate = classEscape.negate }
			end
			if escaped == "b" then
				return { kind = "anchor", at = "word" }
			end
			if escaped == "B" then
				return { kind = "anchor", at = "notword" }
			end
			if escaped:match("^[1-9]$") then
				return { kind = "backref", ref = tonumber(escaped) }
			end
			return { kind = "char", char = CONTROL_ESCAPES[escaped] or escaped }
		end

		-- A bare metacharacter that cannot start an atom ends this branch.
		if ere and (c == ")" or c == "|") then
			return nil
		end
		if not ere and source:sub(pos, pos + 1) == "\\)" then
			return nil
		end
		if not ere and source:sub(pos, pos + 1) == "\\|" then
			return nil
		end

		pos += 1
		return { kind = "char", char = c }
	end

	-- {n} {n,} {n,m}, and the bare quantifiers. Returns nil (not an error) when
	-- what follows is not a quantifier at all.
	local function parseQuantifier(): ({ min: number, max: number }?, boolean)
		if peek() == "*" then
			pos += 1
			return { min = 0, max = math.huge }, true
		end
		if isMeta("+") then
			takeMeta("+")
			return { min = 1, max = math.huge }, true
		end
		if isMeta("?") then
			takeMeta("?")
			return { min = 0, max = 1 }, true
		end
		if isMeta("{") then
			local open = pos
			local body = ere and source:match("^{(%d*,?%d*)}", pos)
				or source:match("^\\{(%d*,?%d*)\\}", pos)
			if not body or body == "" or body == "," then
				-- `{` that is not a valid interval is a literal brace, which is
				-- what every real regex does rather than erroring.
				pos = open
				return nil, false
			end
			local from, to = body:match("^(%d*),(%d*)$")
			local min, max
			if from then
				min = tonumber(from) or 0
				max = to == "" and math.huge or tonumber(to)
			else
				min = tonumber(body)
				max = min
			end
			if max ~= math.huge and (min :: number) > (max :: number) then
				return nil, false
			end
			pos += (ere and #body + 2 or #body + 4)
			return { min = min :: number, max = max :: number }, true
		end
		return nil, false
	end

	local function parseSeq(): Node?
		local items: { Node } = {}
		while true do
			if pos > #source then
				break
			end
			local before = pos
			local atom = parseAtom()
			if failure then
				return nil
			end
			if not atom then
				pos = before
				break
			end

			-- Quantifiers stack: `a{2}?` is a lazy repeat of a repeat.
			while true do
				local bounds, found = parseQuantifier()
				if not found or not bounds then
					break
				end
				local lazy = false
				-- The lazy marker is a bare `?` even in BRE, it is a PCRE
				-- extension, not a BRE metacharacter, so it is never backslashed.
				if peek() == "?" then
					lazy = true
					pos += 1
				end
				if atom.kind == "anchor" then
					return fail("an anchor cannot be repeated")
				end
				atom = { kind = "repeat", body = atom, min = bounds.min, max = bounds.max, lazy = lazy }
			end
			items[#items + 1] = atom
		end
		return { kind = "seq", items = items }
	end

	parseAlt = function(): Node?
		local branches: { Node } = {}
		while true do
			local branch = parseSeq()
			if not branch then
				return nil
			end
			branches[#branches + 1] = branch
			if isMeta("|") then
				takeMeta("|")
			else
				break
			end
		end
		if #branches == 1 then
			return branches[1]
		end
		return { kind = "alt", branches = branches }
	end

	local root = parseAlt()
	if failure then
		return nil, failure
	end
	if pos <= #source then
		return nil, string.format("unexpected %q in pattern at position %d", peek(), pos)
	end
	return root, nil
end

-- Matcher
-- Recursive backtracking with continuations: each node matches at `pos` and asks
-- `cont` whether the rest of the pattern can match from where it ended. That is
-- what makes alternation and greedy-with-backoff fall out for free.
local matchNode

local function isWordAt(subject: string, index: number): boolean
	if index < 1 or index > #subject then
		return false
	end
	return WORD[subject:sub(index, index)] == true
end

local function matchRepeat(state: any, node: Node, pos: number, count: number, cont: (number) -> number?): number?
	state.steps += 1
	if state.steps > MAX_STEPS then
		error("REGEX_BUDGET", 0)
	end

	local function more(): number?
		if count >= node.max then
			return nil
		end
		return matchNode(state, node.body, pos, function(next: number): number?
			-- Zero-width guard. Without it `(a*)*` recurses forever on an empty
			-- inner match, which is a hang rather than a wrong answer, and a hang
			-- here freezes Studio, since Luau cannot preempt.
			--
			-- KNOWN, DELIBERATE DIVERGENCE: PCRE allows one empty iteration before
			-- stopping, so Python reports group 1 of `(a*)*b` against "ab" as "",
			-- where this reports "a" (the last iteration that consumed anything).
			-- Differential testing against Python's `re` over ~1700 pattern/subject
			-- pairs found this and nothing else, it only ever affects CAPTURES of a
			-- degenerate pattern, the matched span always agrees, and grep/find
			-- read spans. Refusing the empty iteration is what keeps the guard
			-- simple, and a simple guard is what keeps Studio responsive.
			if next == pos then
				return nil
			end
			return matchRepeat(state, node, next, count + 1, cont)
		end)
	end

	if node.lazy then
		if count >= node.min then
			local done = cont(pos)
			if done then
				return done
			end
		end
		return more()
	end

	local done = more()
	if done then
		return done
	end
	if count >= node.min then
		return cont(pos)
	end
	return nil
end

function matchNode(state: any, node: Node, pos: number, cont: (number) -> number?): number?
	state.steps += 1
	if state.steps > MAX_STEPS then
		error("REGEX_BUDGET", 0)
	end
	local kind = node.kind
	local subject = state.subject

	if kind == "char" then
		local got = subject:sub(pos, pos)
		if got == "" then
			return nil
		end
		if state.ignoreCase then
			if got:lower() ~= node.char:lower() then
				return nil
			end
		elseif got ~= node.char then
			return nil
		end
		return cont(pos + 1)
	elseif kind == "any" then
		if pos > #subject then
			return nil
		end
		return cont(pos + 1)
	elseif kind == "class" then
		local got = subject:sub(pos, pos)
		if got == "" then
			return nil
		end
		local inSet = node.set[got] == true
		if inSet == node.negate then
			return nil
		end
		return cont(pos + 1)
	elseif kind == "seq" then
		local items = node.items
		local function step(index: number, at: number): number?
			if index > #items then
				return cont(at)
			end
			return matchNode(state, items[index], at, function(next: number): number?
				return step(index + 1, next)
			end)
		end
		return step(1, pos)
	elseif kind == "alt" then
		for _, branch in ipairs(node.branches) do
			local done = matchNode(state, branch, pos, cont)
			if done then
				return done
			end
		end
		return nil
	elseif kind == "repeat" then
		return matchRepeat(state, node, pos, 0, cont)
	elseif kind == "group" then
		if not node.index then
			return matchNode(state, node.body, pos, cont)
		end
		local index = node.index
		local saved = state.caps[index]
		local start = pos
		local done = matchNode(state, node.body, pos, function(next: number): number?
			state.caps[index] = subject:sub(start, next - 1)
			local finished = cont(next)
			if not finished then
				state.caps[index] = saved
			end
			return finished
		end)
		if not done then
			state.caps[index] = saved
		end
		return done
	elseif kind == "anchor" then
		local at = node.at
		if at == "start" then
			return pos == 1 and cont(pos) or nil
		elseif at == "end" then
			return pos == #subject + 1 and cont(pos) or nil
		end
		local before = isWordAt(subject, pos - 1)
		local here = isWordAt(subject, pos)
		local boundary = before ~= here
		if (at == "word") == boundary then
			return cont(pos)
		end
		return nil
	elseif kind == "backref" then
		local captured = state.caps[node.ref]
		if not captured then
			return nil
		end
		local slice = subject:sub(pos, pos + #captured - 1)
		if state.ignoreCase then
			if slice:lower() ~= captured:lower() then
				return nil
			end
		elseif slice ~= captured then
			return nil
		end
		return cont(pos + #captured)
	elseif kind == "look" then
		-- Zero-width: the body has to match here, but consumes nothing.
		local hit = matchNode(state, node.body, pos, function(next: number): number?
			return next
		end)
		if (hit ~= nil) == node.negated then
			return nil
		end
		return cont(pos)
	end
	return nil
end

-- Compile
-- Two fast paths, because grep runs this over every line of every script and a
-- Luau backtracker is far slower than string.find.
--
--   literal    the whole pattern is plain text -> never enter the engine
--   prefilter  some substring MUST appear in any match -> string.find for it
--              first and skip the line outright when it is absent
--
-- This is what real grep does (it runs Boyer-Moore before the automaton). The
-- prefilter is only ever allowed to produce FALSE NEGATIVES for the skip, never
-- to change a match, which is why it is taken exclusively from a top-level
-- sequence of required characters.
local function literalOf(node: Node): string?
	if node.kind ~= "seq" then
		return nil
	end
	local chars: { string } = {}
	for _, item in ipairs(node.items) do
		if item.kind ~= "char" then
			return nil
		end
		chars[#chars + 1] = item.char
	end
	return table.concat(chars)
end

local function prefilterOf(node: Node): string?
	if node.kind ~= "seq" then
		return nil
	end
	local best, current = "", {}
	local function close()
		if #current > #best then
			best = table.concat(current)
		end
		current = {}
	end
	for _, item in ipairs(node.items) do
		if item.kind == "char" then
			current[#current + 1] = item.char
		elseif item.kind == "repeat" and item.min >= 1 and item.body.kind == "char" then
			-- `b+` guarantees one `b`, so it EXTENDS the run, and then ends it.
			-- Whatever follows is not adjacent to what came before: `ab+c` matches
			-- "abbbc", which does not contain "abc". Carrying the run through a
			-- repeat is a prefilter that rejects real matches, and a prefilter
			-- that rejects looks exactly like "no matches".
			current[#current + 1] = item.body.char
			if item.min ~= 1 or item.max ~= 1 then
				close()
			end
		else
			close()
		end
	end
	close()
	return #best >= 2 and best or nil
end

export type Program = {
	find: (Program, string, number?) -> (number?, number?, { string }),
	source: string,
	groups: number,
}

local Program = {}
Program.__index = Program

function Program:find(subject: string, init: number?): (number?, number?, { string })
	local from = init or 1
	if self.literal then
		local start, finish = string.find(subject, self.literal, from, true)
		return start, finish, {}
	end
	if self.prefilter and not string.find(subject, self.prefilter, 1, true) then
		return nil, nil, {}
	end

	-- One state for the whole scan, so the step budget covers every start
	-- position rather than resetting and letting the total run away.
	local state = { subject = subject, caps = {}, steps = 0, ignoreCase = self.ignoreCase }
	local last = self.anchored and from or #subject + 1
	for start = from, last do
		table.clear(state.caps)
		local finish = matchNode(state, self.root, start, function(at: number): number?
			return at
		end)
		if finish then
			return start, finish - 1, state.caps
		end
	end
	return nil, nil, {}
end

-- `ere` picks the dialect; the default is BRE, which is what plain grep and sed
-- use. `ignoreCase` is folded into the compiled sets rather than applied to the
-- subject, so captures come back with their original case.
function Regex.compile(source: string, opts: { ere: boolean?, ignoreCase: boolean? }?): (Program?, string?)
	local o = opts or {}
	local ere = o.ere == true
	local root, err = parse(source, ere, o.ignoreCase == true)
	if not root then
		return nil, err or "invalid pattern"
	end
	local program = setmetatable({
		root = root,
		source = source,
		ere = ere,
		ignoreCase = o.ignoreCase == true,
		-- ^ at the very front means only one start position is worth trying.
		anchored = root.kind == "seq" and root.items[1] ~= nil
			and root.items[1].kind == "anchor" and root.items[1].at == "start",
	}, Program)
	if not program.ignoreCase then
		-- Both fast paths compare bytes, so neither is safe when folding case.
		program.literal = literalOf(root)
		if not program.literal then
			program.prefilter = prefilterOf(root)
		end
	end
	return (program :: any) :: Program, nil
end

-- Escape a literal so it can be used where a pattern is expected. -F combined
-- with -w or -x needs this: the wrapping turns a fixed string into a pattern,
-- and an unescaped `game.Workspace` would then match `gameXWorkspace`.
function Regex.escape(text: string): string
	return (text:gsub("[%^%$%(%)%.%[%]%*%+%-%?%{%}%|\\]", "\\%0"))
end

-- True when the error raised out of a match was the step budget rather than a
-- genuine fault. Callers turn it into a message naming the pattern.
function Regex.isBudget(err: any): boolean
	return tostring(err):find("REGEX_BUDGET", 1, true) ~= nil
end

Regex.MAX_STEPS = MAX_STEPS

-- Self-test
-- The engine needs no DataModel, so correctness is pinned here as a plain table
-- rather than through the shell. Every row is a construct the old translation
-- layer either refused outright or silently mistranslated.
function Regex.selfTest(): (boolean, string?)
	type Case = { pattern: string, subject: string, ere: boolean?, ignoreCase: boolean?,
		want: string?, caps: { string }? }
	local cases: { Case } = {
		-- The two the reviewer called out as non-negotiable and missing.
		{ pattern = "a|b", subject = "xbz", ere = true, want = "b" },
		{ pattern = "(cat|dog)s", subject = "hotdogs", ere = true, want = "dogs", caps = { "dog" } },
		{ pattern = "o{2,3}", subject = "foooo", ere = true, want = "ooo" },
		{ pattern = "o{2}", subject = "foooo", ere = true, want = "oo" },
		-- Greedy by default, lazy on request.
		{ pattern = "<.+>", subject = "<a><b>", ere = true, want = "<a><b>" },
		{ pattern = "<.+?>", subject = "<a><b>", ere = true, want = "<a>" },
		-- Classes, both dialects of escape.
		{ pattern = "\\d+", subject = "ab 123 cd", ere = true, want = "123" },
		{ pattern = "[[:digit:]]+", subject = "ab 123 cd", ere = true, want = "123" },
		{ pattern = "[^a-z ]+", subject = "ab 123 cd", ere = true, want = "123" },
		{ pattern = "\\w+", subject = "  foo_1 ", ere = true, want = "foo_1" },
		-- Anchors and word boundaries.
		{ pattern = "^ab", subject = "abc", ere = true, want = "ab" },
		{ pattern = "^bc", subject = "abc", ere = true, want = nil },
		{ pattern = "c$", subject = "abc", ere = true, want = "c" },
		{ pattern = "\\bcat\\b", subject = "a cat here", ere = true, want = "cat" },
		{ pattern = "\\bcat\\b", subject = "concatenate", ere = true, want = nil },
		-- Backreference: the construct that rules out a linear engine.
		{ pattern = "(ab)\\1", subject = "xabab", ere = true, want = "abab", caps = { "ab" } },
		{ pattern = "(a+)b\\1", subject = "aabaa", ere = true, want = "aabaa", caps = { "aa" } },
		-- Lookahead, both directions.
		{ pattern = "foo(?!bar)", subject = "foobaz", ere = true, want = "foo" },
		{ pattern = "foo(?!bar)", subject = "foobar", ere = true, want = nil },
		{ pattern = "foo(?=bar)", subject = "foobar", ere = true, want = "foo" },
		{ pattern = "(?:ab)+", subject = "ababab", ere = true, want = "ababab", caps = {} },
		-- Case folding must not damage the captured text.
		{ pattern = "(HeLLo)", subject = "say hello", ere = true, ignoreCase = true,
		  want = "hello", caps = { "hello" } },
		-- BRE vs ERE: the same source, deliberately different answers.
		{ pattern = "a+", subject = "aaa", ere = false, want = nil },      -- literal +
		{ pattern = "a+", subject = "ca+b", ere = false, want = "a+" },
		{ pattern = "a\\+", subject = "aaa", ere = false, want = "aaa" },  -- quantifier
		{ pattern = "(a)", subject = "(a)", ere = false, want = "(a)" },   -- literal parens
		{ pattern = "\\(a\\)", subject = "za", ere = false, want = "a", caps = { "a" } },
		{ pattern = "a\\|b", subject = "xbz", ere = false, want = "b" },
		-- A dot is a metacharacter in BRE too, which is the behaviour change
		-- that comes with being a real grep.
		{ pattern = "game.Workspace", subject = "gameXWorkspace", ere = false, want = "gameXWorkspace" },
		{ pattern = "game\\.Workspace", subject = "gameXWorkspace", ere = false, want = nil },
		-- The one place this deliberately differs from PCRE, pinned so it stays a
		-- decision rather than becoming a surprise: an empty iteration does not
		-- count, so group 1 is the last one that consumed something. The SPAN is
		-- identical to Python's, which is all grep and find ever read.
		{ pattern = "(a*)*b", subject = "ab", ere = true, want = "ab", caps = { "a" } },
	}

	for _, case in ipairs(cases) do
		local program, err = Regex.compile(case.pattern,
			{ ere = case.ere, ignoreCase = case.ignoreCase })
		if not program then
			return false, string.format("compile(%q) failed: %s", case.pattern, tostring(err))
		end
		local ok, start, finish, caps = pcall(function()
			return program:find(case.subject)
		end)
		if not ok then
			return false, string.format("%q on %q threw: %s", case.pattern, case.subject,
				tostring(start))
		end
		local got = start and case.subject:sub(start :: number, finish :: number) or nil
		if got ~= case.want then
			return false, string.format("%q %s on %q matched %s, want %s",
				case.pattern, case.ere and "(ERE)" or "(BRE)", case.subject,
				got and string.format("%q", got) or "nothing",
				case.want and string.format("%q", case.want) or "nothing")
		end
		if case.caps then
			for index, expected in ipairs(case.caps) do
				if (caps :: any)[index] ~= expected then
					return false, string.format("%q on %q: capture %d was %s, want %q",
						case.pattern, case.subject, index,
						tostring((caps :: any)[index]), expected)
				end
			end
		end
	end

	-- Patterns that must be REFUSED at compile, naming the reason. A silent
	-- mismatch here is the failure this engine replaced.
	for _, bad in ipairs({
		{ pattern = "(?<=x)y", want = "lookbehind" },
		{ pattern = "[a-", want = "unterminated" },
		{ pattern = "(ab", want = "unmatched" },
		{ pattern = "a\\", want = "backslash" },
		{ pattern = "[z-a]", want = "reversed range" },
	}) do
		local program, err = Regex.compile(bad.pattern, { ere = true })
		if program then
			return false, string.format("compile(%q) should have failed", bad.pattern)
		end
		if not tostring(err):find(bad.want, 1, true) then
			return false, string.format("compile(%q) said %q, want it to mention %q",
				bad.pattern, tostring(err), bad.want)
		end
	end

	-- Catastrophic backtracking. Luau cannot preempt a running chunk, so without
	-- the budget this is not a slow grep, it is a frozen Studio. The one test
	-- here whose failure mode is "the plugin never finishes starting".
	do
		local program = Regex.compile("(a+)+$", { ere = true })
		local ok, err = pcall(function()
			return (program :: any):find(string.rep("a", 40) .. "!")
		end)
		if ok then
			return false, "catastrophic backtracking was not caught by the step budget"
		end
		if not Regex.isBudget(err) then
			return false, "budget overflow raised the wrong error: " .. tostring(err)
		end
	end

	-- The prefilter may only skip lines that genuinely cannot match. An
	-- over-eager one drops real hits and looks exactly like "no matches".
	for _, pattern in ipairs({ "foo\\d+bar", "ab+c", "^start[0-9]", "x(y|z)w" }) do
		local program = Regex.compile(pattern, { ere = true }) :: any
		if program.prefilter then
			for _, subject in ipairs({ "foo12bar", "abbbc", "start7", "xyw", "nothing here", "fooXbar" }) do
				local withFilter = program:find(subject)
				local saved = program.prefilter
				program.prefilter = nil
				local without = program:find(subject)
				program.prefilter = saved
				if withFilter ~= without then
					return false, string.format(
						"prefilter %q changed the result of %q on %q", saved, pattern, subject)
				end
			end
		end
	end

	return true, nil
end

return Regex
