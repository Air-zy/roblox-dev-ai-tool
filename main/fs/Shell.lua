--!optimize 2
-- Shell.luau: the command line: parsing, composition, and the command table.
--
-- Split from Terminal on the seam that was already there. Terminal knows how to
-- do things to the DataModel, list a container, read a script's source, clone
-- an instance. This file knows how to read a line someone typed and work out
-- which of those to call, in what order, with what plumbed into what: quoting,
-- heredocs, `|` pipelines, `;` `&&` `||` chaining, `>` redirection.
--
-- The two halves change for unrelated reasons, which is why they are two files.
-- A new command is a HANDLERS entry; a new piece of syntax is a change here and
-- nowhere else.
--
-- It is deliberately NOT a shell interpreter. No variables, no control flow, no
-- `$?`, no command substitution, no environment. Anything that needs real
-- composition should use the `run` tool instead of growing a language here.

local Fs = require(script.Parent:WaitForChild("Fs"))
-- Only for find's -type, which has to reject a name that is not a class BEFORE
-- walking: IsA() returns false for an invented class rather than throwing, so an
-- unvalidated -type walks the whole subtree and reports a bare "no matches"
-- indistinguishable from a pattern that genuinely matched nothing.
local Props = require(script.Parent.Parent:WaitForChild("studio"):WaitForChild("Props"))
-- The pattern engine. grep, sed and find all speak real BRE/ERE now rather than
-- Lua patterns in a costume, and this is where that lives.
local Regex = require(script.Parent.Parent:WaitForChild("text"):WaitForChild("Regex"))
-- The sed engine. Its handler stays here; what sed means lives in text/Sed.
local Sed = require(script.Parent.Parent:WaitForChild("text"):WaitForChild("Sed"))
local parseSedCommand = Sed.parseSedCommand
local sedSelects = Sed.sedSelects
local substitute = Sed.substitute
local TR_ESCAPES = Sed.ESCAPES
-- The only reach out of fs/: the shell has to know which words are tools rather
-- than commands, so it can say so instead of reporting "unknown command".
local Tools = require(script.Parent.Parent:WaitForChild("agent"):WaitForChild("Tools"))

local isScript     = Fs.isScript
local getSource    = Fs.getSource
local splitLines   = Fs.splitLines
local instancePath = Fs.instancePath
local withUndo     = Fs.withUndo
local splitPath    = Fs.splitPath
local nameMatcher  = Fs.nameMatcher
-- `ls` renders a script as Main.luau, so every name match has to be tried
-- against that form too, a model searching `*.luau` read it out of a listing.
-- Missing from these aliases is how `find -name` came to call a nil global.
local displayName  = Fs.displayName

-- Not shell commands at all, they exist as tools, because "create an instance
-- of class X" and "assign a typed property" have no bash equivalent to borrow a
-- prior from. Naming them turns a wrong guess into one corrective turn. Asked of
-- the registry rather than listed, so a tool added later is recognised the
-- moment its file lands.
local function isSeparateTool(cmd: string): boolean
	return cmd ~= "bash" and Tools.has(cmd)
end

-- Same number as Terminal's MAX_RESULTS, which caps find and grep. Duplicated
-- rather than shared because Terminal requires Shell, not the other way round,
-- and one integer is a cheaper price than inverting that.
local MAX_LIST = 100

local Shell = {}

-- Command-line parsing
-- Inside double quotes bash only escapes these four; a backslash before anything
-- else is an ordinary character. Getting that wrong is not cosmetic: `grep -nE
-- "^\t###"` used to arrive as `^t###`, so the search ran against a pattern nobody
-- wrote and came back "no matches", a still-broken command reading as a
-- verified-absent result, which is the one output there is no way to doubt.
local DOUBLE_QUOTE_ESCAPES: { [string]: boolean } = {
	['"'] = true, ["\\"] = true, ["$"] = true, ["`"] = true,
}

-- Split a shell-ish line into argv, honouring quotes so instance names with
-- spaces survive: `cd "My Model"` is the common case, and a plain split on
-- whitespace gets it wrong on day one.
--
-- ponytail: not a shell. No variables, command substitution or control flow, and
-- no reason to add them, anything that needs those should use `run`. Ceiling:
-- the quote/escape rules are bash's, the composition is `| ; && ||` and nothing
-- more, and a real grammar is the upgrade path if that ever stops being enough.
--
-- Returns a third value: which argv POSITIONS came out of quotes, so the
-- metacharacter check can tell `grep "<" f` from an input redirection.
local function tokenize(line: string): ({ string }?, string?, { [number]: boolean })
	local args: { string } = {}
	local buf: { string } = {}
	local quoted: { [number]: boolean } = {}
	local sawQuote = false
	local quote: string? = nil

	local function flush()
		if #buf > 0 then
			args[#args + 1] = table.concat(buf)
			if sawQuote then
				quoted[#args] = true
			end
			buf = {}
			sawQuote = false
		end
	end

	local i = 1
	while i <= #line do
		local c = line:sub(i, i)
		if c == "\\" and quote == nil then
			i += 1
			buf[#buf + 1] = line:sub(i, i)
		elseif c == "\\" and quote == '"' then
			local following = line:sub(i + 1, i + 1)
			if DOUBLE_QUOTE_ESCAPES[following] then
				i += 1
				buf[#buf + 1] = following
			else
				buf[#buf + 1] = c
			end
		elseif quote then
			if c == quote then
				quote = nil
			else
				buf[#buf + 1] = c
			end
		elseif c == "'" or c == '"' then
			quote = c
			sawQuote = true
			buf[#buf + 1] = ""          -- mark: "" is a real, empty argument
		elseif c == ";" then
			-- Its own token even when glued to a word, so `echo foo;` is two
			-- commands rather than one argument ending in a semicolon. A quoted
			-- ";" never reaches here, the quote branch above claims it first.
			flush()
			args[#args + 1] = ";"
		elseif c == "|" or c == "&" then
			-- Doubled or single, glued or spaced: `ls|wc`, `a && b`, `a||b`.
			flush()
			if line:sub(i + 1, i + 1) == c then
				args[#args + 1] = c .. c
				i += 1
			else
				args[#args + 1] = c
			end
		elseif c == "\n" then
			-- A newline ends a command, exactly as it does in a shell script.
			-- It used to fall through to the whitespace branch below and act as
			-- an ARGUMENT separator, so a perfectly ordinary two-line tool call
			--     ls /Workspace
			--     cat Main.luau
			-- ran as the single command `ls /Workspace cat Main.luau`, one
			-- listing, the second line silently swallowed as operands. Nothing
			-- errored, which is what made it expensive: the model saw plausible
			-- output and moved on. A quoted newline never reaches here, so
			-- multi-line strings still survive intact.
			flush()
			args[#args + 1] = ";"
		elseif c:match("%s") then
			flush()
		else
			buf[#buf + 1] = c
		end
		i += 1
	end
	-- Same as bash: `grep don't` is an error, not a silently mangled pattern.
	if quote then
		return nil, "unterminated " .. quote .. " quote", quoted
	end
	flush()
	return args, nil, quoted
end

-- What a command accepts, declared once and checked once, in runCommand,
-- before the handler runs, so an unknown flag fails on its own terms instead of
-- surviving as an ignored flag and a stray positional argument.
--
--   bool   letters that are on/off
--   value  letters that consume an argument, glued (-A3, -n20, -tSEP) or
--          spaced (-A 3). This is the field that did not exist before, and its
--          absence is the whole reason the flag coverage was thin: every flag
--          carrying a value needed a bespoke lifter ahead of partition, so
--          `-m N`, `-k N`, `-t SEP` and `-e PAT` each meant another one.
--   long   a `--word` mapped to "bool", "value", or "optval" (an inline
--          `--color=auto` only, never consuming the next argument, which would
--          eat the path)
--   why    the reason a flag CANNOT exist against a DataModel. The refusal then
--          names it instead of listing what IS allowed and leaving the caller to
--          work out which part of the idea was wrong. Same trick as UNSUPPORTED
--          below: the explanation rides on the one call that needed it and costs
--          nothing on every call that didn't.
export type FlagSpec = {
	bool: string?,
	value: string?,
	long: { [string]: string }?,
	why: { [string]: string }?,
}

-- Render a spec for an error message: "-c -l -n --include".
local function flagNames(spec: FlagSpec): string
	local names: { string } = {}
	for char in ((spec.bool or "") .. (spec.value or "")):gmatch(".") do
		names[#names + 1] = "-" .. char
	end
	table.sort(names)
	local longs: { string } = {}
	for name in pairs(spec.long or {}) do
		longs[#longs + 1] = name
	end
	table.sort(longs)
	table.move(longs, 1, #longs, #names + 1, names)
	if #names == 0 then
		return "no flags"
	end
	return table.concat(names, " ")
end

local EMPTY_SPEC: FlagSpec = {}

-- Split argv into a flag set, the values those flags carried, and positional
-- operands, so no handler has to re-derive them. Short flags bundle the way they
-- do in bash (-rn is -r -n), and a value letter ends its bundle by swallowing
-- whatever is left of the token (-nA3 is -n and -A 3).
--
-- A lone "-" and a bare "-20" are operands, not flags: `head -20` means twenty
-- lines, and losing that to the flag set is how `head -20 x` becomes `head x`.
--
-- Without a spec every flag is taken on faith, which is how an unimplemented
-- flag became a silent wrong answer: `grep -A 3 pat f` put -A in the set nobody
-- read, left `3` as a positional, and reported `no child named "3"`, an error
-- naming the argument for the absence of the flag. See SPECS, where every
-- command declares its own.
local function partition(argv: { string }, spec: FlagSpec?):
	({ [string]: boolean }, { [string]: { string } }, { string }, string?)
	local flags: { [string]: boolean } = {}
	local values: { [string]: { string } } = {}
	local operands: { string } = {}
	local cmd = argv[1] or "?"
	-- No spec means "not checked here": `find` parses its own GNU-style long
	-- options and refuses unknown ones itself, so the gate must let them past.
	local checked = spec ~= nil
	local s = spec or EMPTY_SPEC

	-- Presence lands in `flags` even for a value flag, so a handler that only
	-- needs "was it given?" does not have to reach into `values` for it.
	local function record(flag: string, value: string?)
		flags[flag] = true
		if value ~= nil then
			local list = values[flag]
			if list then
				list[#list + 1] = value
			else
				values[flag] = { value }
			end
		end
	end

	local function refuse(flag: string): string
		local why = s.why and s.why[flag]
		if why then
			return string.format("%s %s", flag, why)
		end
		return string.format("unsupported flag %s — %s takes %s", flag, cmd, flagNames(s))
	end

	local i = 2
	local endOfFlags = false
	while i <= #argv do
		local arg = argv[i]
		if endOfFlags then
			operands[#operands + 1] = arg
		elseif arg == "--" then
			-- bash's end-of-options marker, and the only way to name a path that
			-- begins with a dash.
			endOfFlags = true
		elseif arg:sub(1, 2) == "--" then
			local name, glued = arg:match("^([^=]+)=(.*)$")
			name = name or arg
			-- A spec entry is "kind" or "kind:-x", where -x is the short flag this
			-- long one spells out. The alias lives WITH the command because it is
			-- not global: --lines is -n for head and -l for wc, and one shared
			-- table would have to pick a side and be wrong for the other.
			local declared = s.long and s.long[name]
			local kind, short = declared, nil
			if declared then
				local colon = declared:find(":", 1, true)
				if colon then
					kind = declared:sub(1, colon - 1)
					short = declared:sub(colon + 1)
				end
			end
			if checked and not kind then
				return flags, values, operands, refuse(name)
			end
			-- Recorded under the short name as well, so every handler reads one
			-- spelling. A handler checking both would be the declared-but-ignored
			-- trap in a new shape, and forgetting the second check is invisible.
			local function recordBoth(value: string?)
				record(name, value)
				if short then
					record(short, value)
				end
			end
			if kind == "value" then
				local value = glued
				if not value then
					value = argv[i + 1]
					i += 1
				end
				if not value then
					return flags, values, operands,
						string.format("%s needs a value, as `%s=…`", name, name)
				end
				recordBoth(value)
			elseif kind == "optval" or not checked then
				-- optval is `--color` / `--color=auto`: an inline value only, never
				-- the next argument, which would eat the path. Unchecked commands
				-- land here too, since they parse their own long options.
				recordBoth(glued)
			elseif glued then
				return flags, values, operands, string.format("%s takes no value", name)
			else
				recordBoth(nil)
			end
		elseif #arg > 1 and arg:sub(1, 1) == "-" and not arg:match("^%-%d+$") then
			local rest = arg:sub(2)
			while rest ~= "" do
				local char = rest:sub(1, 1)
				rest = rest:sub(2)
				local flag = "-" .. char
				if s.value and s.value:find(char, 1, true) then
					local value = rest
					if value == "" then
						value = argv[i + 1]
						i += 1
					end
					if not value then
						return flags, values, operands, string.format(
							"%s needs a value, as `%s 3` or `%s3`", flag, flag, flag)
					end
					record(flag, value)
					rest = ""
				elseif not checked or (s.bool and s.bool:find(char, 1, true)) then
					record(flag, nil)
				else
					return flags, values, operands, refuse(flag)
				end
			end
		else
			operands[#operands + 1] = arg
		end
		i += 1
	end
	return flags, values, operands, nil
end

-- The last value given for a flag. Repeating one is legal: `grep -e a -e b`
-- reads every occurrence out of `values` directly, and where repetition is
-- meaningless the last wins, as it does in bash.
local function valueOf(values: { [string]: { string } }, flag: string): string?
	local list = values[flag]
	return list and list[#list]
end

local function numberOf(values: { [string]: { string } }, flag: string): number?
	return tonumber(valueOf(values, flag) or "")
end

-- head/tail/tree all take an optional count. Once partition() has removed the
-- -n / -L flag itself, `head -n 20 x`, `head -20 x`, `head x 20` and `head x`
-- all reduce to the same two operands in some order.
local function takeCount(operands: { string }): (string?, number?)
	local path: string? = nil
	local count: number? = nil
	for _, operand in ipairs(operands) do
		-- `-20` means twenty lines, not minus twenty, so the flag form has to be
		-- checked before tonumber, which would happily hand back a negative and
		-- turn `head -20 x` into empty output.
		local number = tonumber(operand:match("^%-(%d+)$") or "") or tonumber(operand)
		if number and number > 0 then
			count = count or math.floor(number)
		else
			path = path or operand
		end
	end
	return path, count
end

-- Split a trailing glob off a path: `/Workspace/Part*` -> "/Workspace", "Part*".
-- Returns nil for the pattern when there is no wildcard, so callers can treat
-- the whole thing as an ordinary path.
local function splitGlob(target: string?): (string?, string?)
	if not target or not target:find("[%*%?]") then
		return target, nil
	end
	local parent, leaf = target:match("^(.*)/([^/]*)$")
	if not leaf then
		return nil, target                      -- bare `ls *.luau`, relative to cwd
	end
	return (parent == "" and "/" or parent), leaf
end

-- Lift a heredoc off the front of a line, returning the command line and the
-- body. This has to happen BEFORE tokenizing: the body is arbitrary source, and
-- one apostrophe in a comment would otherwise blow up the quote tracker.
--
-- There is no parameter expansion here, so `<< EOF` and `<< 'EOF'` mean exactly
-- the same thing, the distinction that makes them differ in bash doesn't exist.
-- `<<-` strips leading tabs from the body and the terminator, as bash does.
local function extractHeredoc(raw: string): (string, string?, string?)
	local head, dash, quote, delim, tail =
		raw:match("^(.-)<<(%-?)[ \t]*(['\"]?)([%w_%-%.]+)%3(.*)$")
	if not delim then
		if raw:find("<<", 1, true) then
			return raw, nil, "heredoc needs a delimiter word, e.g. `cat > x.luau << EOF`"
		end
		return raw, nil, nil
	end

	-- The rest of the first line still belongs to the command: `<< EOF > file`
	-- and `> file << EOF` both have to work.
	local firstLineRest, rawBody = tail:match("^([^\n]*)\n?(.*)$")
	local commandLine = head .. " " .. (firstLineRest or "")

	local content: { string } = {}
	local terminated = false
	local trailing = 0
	local bodyLines = splitLines(rawBody or "")
	for index, line in ipairs(bodyLines) do
		local stripped = line
		if dash == "-" then
			stripped = line:gsub("^\t+", "")
		end
		if stripped == delim then
			terminated = true
			trailing = #bodyLines - index
			break
		end
		content[#content + 1] = stripped
	end

	if not terminated then
		return raw, nil, string.format("heredoc was never terminated by %s", delim)
	end
	if trailing > 0 then
		-- bash would silently ignore this. Here it almost always means the
		-- delimiter appeared inside the body and truncated the script early,
		-- which is the one failure mode worth refusing rather than committing.
		return raw, nil, string.format(
			"%d line(s) came after the closing %s — if %s appears inside the body, " ..
				"pick a delimiter that doesn't", trailing, delim, delim)
	end

	local body = #content > 0 and (table.concat(content, "\n") .. "\n") or ""
	return commandLine, body, nil
end

-- The bit bucket. A path to recognise, not an instance to create: a real
-- Folder named "dev" would live in the place file forever, turn up in every
-- find, and sync to disk.
local DEV_NULL = "/dev/null"

-- Pull redirection out of argv: `> path`, `>> path`, glued or spaced.
--
-- `2>` and `&>` aim at a stderr stream that does not exist here, errors come
-- back as ordinary output, so they are dropped. Without that, `2>/dev/null` is
-- not a redirect token at all (it starts with a digit) and falls through as a
-- positional argument, which is how `find x 2>/dev/null` ends up searching for
-- an instance named "2>/dev/null" and reporting no matches.
local function takeRedirect(argv: { string }): ({ string }, string?, boolean)
	local kept: { string } = {}
	local target: string? = nil
	local append = false
	local i = 1
	while i <= #argv do
		local arg = argv[i]
		local stream, arrow, glued = arg:match("^([12&]?)(>>?)(.*)$")
		if arrow then
			local path = glued
			if path == "" then
				path = argv[i + 1] or ""
				i += 1
			end
			if stream ~= "2" and stream ~= "&" then
				append = arrow == ">>"
				target = path
			end
		else
			kept[#kept + 1] = arg
		end
		i += 1
	end
	return kept, target, append
end

-- Bash commands with no DataModel equivalent. Naming them buys a fast, specific
-- failure; the alternative is not "the model never tries chmod", it is a
-- plausible-looking alias that quietly does the wrong thing, which costs three
-- turns to notice instead of one to correct.
--
-- This is also where the tool description went: an error carries the explanation
-- to the one call that needed it, at zero cost to every call that didn't.
local UNSUPPORTED: { [string]: string } = {
	chown = "instances have no owner — nothing in the DataModel records who made one",
	sudo = "no privilege levels here",
	ps = "no processes; `ls /Workspace` or the run tool is what you want",
	kill = "no processes",
	man = "no man pages; an unknown command lists what exists",
	curl = "use the run tool with HttpService",
	wget = "use the run tool with HttpService",
	-- Named with their replacements, because both are reached for as the fallback
	-- after something else was missing, and "use the run tool" was the answer that
	-- sent a read-only session into a write-capable one.
	awk = "no awk; `sed -n '10,40p'` prints a line range and `grep -A/-B/-C` gives context",
	xargs = "no xargs; pipe into grep/head/tail/wc/sort/uniq/sed/tr instead",
}

-- Which script class a suffix asks for. Owned by Fs, because `write` creates
-- scripts too and the two must not drift apart.
local classFor = Fs.classFor

-- `> path` on a missing path creates the script; so does the `write` tool. One
-- implementation, on Terminal, see Terminal:ensureScript.

-- `&&` and `||` need to know which returned strings were failures. A flag set
-- at the point of failure is honest about it; sniffing for a "cat: " prefix
-- would misread a script whose own first line happens to look like one.
local failed = false
local function fail(prefix: string, err: any): string
	failed = true
	return prefix .. ": " .. tostring(err)
end

local function applyRedirect(self: any, path: string, content: string, append: boolean): string
	local target, err = self:ensureScript(path)
	if not target then
		return fail("bash", err)
	end
	if not isScript(target) then
		return "bash: not a script: " .. instancePath(target)
	end
	local body = content
	if body ~= "" and body:sub(-1) ~= "\n" then
		body ..= "\n"
	end
	if append then
		body = (getSource(target) or "") .. body
	end
	local s, writeErr = self:write(instancePath(target), body)
	return s or fail("bash", writeErr)
end

-- The flag spec for each command. Declared here rather than beside runCommand so
-- it sits next to the handlers that read it, a letter declared and never read
-- is the `rm -rf` bug, where the flag parsed, was dropped on the floor, and the
-- command did something other than what was asked with nothing in the output to
-- say so. selfTest asserts every declared letter is reachable.
--
-- A command absent from this table is unchecked. An empty spec means "takes no
-- flags", which is a real answer and not the same as being absent: `cat -A`
-- should say so rather than quietly ignore the flag.
-- Reasons that come up on more than one command, so the wording cannot drift.
local NO_OWNER = "and an Instance has no owner — nothing in the DataModel records who made it"
local NO_NUL = "separates output with NULs, and everything here is line-oriented text"
local NO_LINKS = "follows symlinks, and nothing resolves through an ObjectValue — see `ln`"
local NO_PROMPT = "prompts before acting, and there is nobody at a terminal to answer"
local PARTIAL_TIME = "compares modification times, and this plugin only knows the ones it " ..
	"has observed since it loaded — an unknown time would silently pick a side"

local SPECS: { [string]: FlagSpec } = {
	basename = {
		bool = "a", value = "s",
		long = { ["--multiple"] = "bool:-a", ["--suffix"] = "value:-s" },
		why = { ["-z"] = NO_NUL },
	},
	cat = {
		-- -e is -vE and -t is -vT, expanded in the handler rather than declared
		-- as separate behaviour.
		bool = "AbeEnstTv",
		long = { ["--number"] = "bool:-n", ["--number-nonblank"] = "bool:-b",
			["--squeeze-blank"] = "bool:-s", ["--show-all"] = "bool:-A",
			["--show-ends"] = "bool:-E", ["--show-tabs"] = "bool:-T" },
		why = { ["-u"] = "disables output buffering, and there is no buffer here to disable" },
	},
	cd = { bool = "LP" },
	chmod = {
		bool = "cfRv",
		long = { ["--recursive"] = "bool:-R", ["--verbose"] = "bool:-v", ["--silent"] = "bool:-f" },
		why = { ["-h"] = NO_LINKS },
	},
	cp = {
		bool = "afnprRTv", value = "t",
		long = { ["--recursive"] = "bool:-R", ["--force"] = "bool:-f", ["--verbose"] = "bool:-v",
			["--no-clobber"] = "bool:-n", ["--target-directory"] = "value:-t",
			["--no-target-directory"] = "bool:-T", ["--archive"] = "bool:-a" },
		why = {
			["-i"] = NO_PROMPT,
			["-u"] = PARTIAL_TIME,
			["-l"] = "makes a hard link, and the DataModel has no such thing — an " ..
				"instance has exactly one Parent. `ln` makes an ObjectValue instead.",
			["-s"] = "makes a symlink; `ln -s` is the command for that here",
		},
	},
	diff = {
		bool = "abBiqrsuwyE", value = "U",
		long = { ["--unified"] = "value:-U", ["--brief"] = "bool:-q", ["--recursive"] = "bool:-r",
			["--ignore-case"] = "bool:-i", ["--ignore-all-space"] = "bool:-w",
			["--ignore-space-change"] = "bool:-b", ["--ignore-blank-lines"] = "bool:-B",
			["--side-by-side"] = "bool:-y", ["--report-identical-files"] = "bool:-s",
			["--color"] = "optval" },
	},
	dirname = { why = { ["-z"] = NO_NUL } },
	du = {
		bool = "achs", value = "d",
		long = { ["--all"] = "bool:-a", ["--summarize"] = "bool:-s", ["--total"] = "bool:-c",
			["--human-readable"] = "bool:-h", ["--max-depth"] = "value:-d" },
		why = { ["-x"] = "stays on one filesystem, and there is only one DataModel" },
	},
	-- echo is deliberately ABSENT: everything after it is data, and the generic
	-- gate refuses any operand starting with a dash. See HANDLERS.echo, which
	-- parses its own leading flags the way echo actually does.
	grep = {
		-- -r/-R and -F are accepted because they are already what this grep does:
		-- it always walks descendants, and it always matches literal text unless
		-- -E/-P is given. -a likewise, there is no binary file here to skip.
		bool = "acEFhHiLlnoPqrRsvwx",
		value = "ABCem",
		long = { ["--include"] = "value", ["--exclude"] = "value", ["--color"] = "optval",
			["--ignore-case"] = "bool:-i", ["--invert-match"] = "bool:-v", ["--count"] = "bool:-c",
			["--line-number"] = "bool:-n", ["--word-regexp"] = "bool:-w", ["--quiet"] = "bool:-q",
			["--only-matching"] = "bool:-o", ["--files-with-matches"] = "bool:-l",
			["--files-without-match"] = "bool:-L", ["--line-regexp"] = "bool:-x",
			["--max-count"] = "value:-m", ["--extended-regexp"] = "bool:-E",
			["--fixed-strings"] = "bool:-F", ["--recursive"] = "bool:-r",
			["--regexp"] = "value:-e", ["--no-filename"] = "bool:-h",
			["--with-filename"] = "bool:-H" },
		why = { ["-z"] = NO_NUL, ["-Z"] = NO_NUL },
	},
	head = {
		bool = "qv", value = "cn",
		long = { ["--lines"] = "value:-n", ["--bytes"] = "value:-c", ["--quiet"] = "bool:-q",
			["--verbose"] = "bool:-v" },
		why = { ["-z"] = NO_NUL },
	},
	ln = {
		bool = "fnsTv",
		long = { ["--symbolic"] = "bool:-s", ["--force"] = "bool:-f", ["--verbose"] = "bool:-v" },
	},
	ls = {
		bool = "1aAcdFhilpqrRStUQ",
		long = { ["--color"] = "optval", ["--all"] = "bool:-a", ["--long"] = "bool:-l",
			["--recursive"] = "bool:-R", ["--reverse"] = "bool:-r",
			["--human-readable"] = "bool:-h", ["--directory"] = "bool:-d",
			["--inode"] = "bool:-i", ["--classify"] = "bool:-F", ["--quote-name"] = "bool:-Q" },
		why = {
			["-g"] = "prints the owning group, " .. NO_OWNER,
			["-o"] = "prints the owner, " .. NO_OWNER,
			["-G"] = "suppresses the group column, " .. NO_OWNER,
			["-n"] = "prints numeric owner ids, " .. NO_OWNER,
			["-u"] = "sorts by access time, and nothing here records a read — " ..
				"-t sorts by the modification times this plugin has observed",
			["-s"] = "prints allocated blocks, and an Instance has no storage size — " ..
				"-S sorts by source bytes (scripts) or descendant count",
			["-L"] = NO_LINKS,
			["-H"] = NO_LINKS,
		},
	},
	mkdir = {
		bool = "pv",
		long = { ["--parents"] = "bool:-p", ["--verbose"] = "bool:-v" },
		why = { ["-m"] = "sets permission bits at creation, and a Folder has none — " ..
			"see `chmod` for the three bits that do exist" },
	},
	mv = {
		bool = "fnTv", value = "t",
		long = { ["--force"] = "bool:-f", ["--no-clobber"] = "bool:-n", ["--verbose"] = "bool:-v",
			["--target-directory"] = "value:-t", ["--no-target-directory"] = "bool:-T" },
		why = { ["-i"] = NO_PROMPT, ["-u"] = PARTIAL_TIME },
	},
	rm = {
		bool = "dfrRv",
		long = { ["--recursive"] = "bool:-R", ["--force"] = "bool:-f", ["--verbose"] = "bool:-v",
			["--dir"] = "bool:-d" },
		why = { ["-i"] = NO_PROMPT, ["-I"] = NO_PROMPT },
	},
	sed = {
		bool = "Einrs", value = "e",
		long = { ["--in-place"] = "bool:-i", ["--quiet"] = "bool:-n", ["--silent"] = "bool:-n",
			["--regexp-extended"] = "bool:-E", ["--expression"] = "value:-e" },
		why = { ["-z"] = NO_NUL },
	},
	sort = {
		bool = "bcfnrRsuV", value = "kot",
		long = { ["--reverse"] = "bool:-r", ["--unique"] = "bool:-u", ["--numeric-sort"] = "bool:-n",
			["--ignore-case"] = "bool:-f", ["--ignore-leading-blanks"] = "bool:-b",
			["--version-sort"] = "bool:-V", ["--random-sort"] = "bool:-R", ["--check"] = "bool:-c",
			["--stable"] = "bool:-s", ["--key"] = "value:-k", ["--field-separator"] = "value:-t",
			["--output"] = "value:-o" },
		why = { ["-h"] = "sorts by human-readable size suffixes, and -n already sorts " ..
			"the numbers this shell emits" },
	},
	stat = { value = "c", long = { ["--format"] = "value:-c" }, why = { ["-L"] = NO_LINKS } },
	tail = {
		bool = "qv", value = "cn",
		long = { ["--lines"] = "value:-n", ["--bytes"] = "value:-c", ["--quiet"] = "bool:-q",
			["--verbose"] = "bool:-v" },
		why = {
			-- The one refusal here that is about THIS program rather than about the
			-- DataModel: a script's .Source really does change and
			-- GetPropertyChangedSignal would see it. What rules it out is that
			-- following never RETURNS, it would hold the turn and one of the six
			-- available WebStreamClients open until something else killed it.
			-- Yielding itself is fine here; blocking forever is not.
			["-f"] = "follows a file as it grows, and a command that never returns would " ..
				"hang the turn it was called from. Re-run tail to see new lines.",
			["-F"] = "follows a file as it grows; see -f",
			["-z"] = NO_NUL,
		},
	},
	touch = {
		bool = "acmv", value = "dtr",
		long = { ["--no-create"] = "bool:-c", ["--date"] = "value:-d",
			["--reference"] = "value:-r", ["--verbose"] = "bool:-v" },
		why = { ["-h"] = NO_LINKS },
	},
	tr = {
		bool = "cCdst",
		long = { ["--delete"] = "bool:-d", ["--squeeze-repeats"] = "bool:-s",
			["--complement"] = "bool:-c", ["--truncate-set1"] = "bool:-t" },
	},
	tree = {
		bool = "adfFi", value = "LPI",
		long = { ["--dirsfirst"] = "bool" },
	},
	uniq = {
		bool = "cdDiu", value = "fsw",
		long = { ["--count"] = "bool:-c", ["--repeated"] = "bool:-d",
			["--all-repeated"] = "bool:-D", ["--unique"] = "bool:-u",
			["--ignore-case"] = "bool:-i", ["--skip-fields"] = "value:-f",
			["--skip-chars"] = "value:-s", ["--check-chars"] = "value:-w" },
	},
	wc = {
		bool = "clLmw",
		long = { ["--lines"] = "bool:-l", ["--words"] = "bool:-w", ["--bytes"] = "bool:-c",
			["--chars"] = "bool:-m", ["--max-line-length"] = "bool:-L" },
	},
	which = { bool = "a", long = { ["--all"] = "bool:-a" } },
	pwd = { bool = "LP" },
	whoami = {},
}
-- Aliases share their target's spec rather than restating it, so a flag added to
-- one is available on the other by construction.
SPECS.egrep = SPECS.grep
SPECS.fgrep = SPECS.grep
-- rmdir is NOT rm with another name: it takes -p (climb and remove emptied
-- parents) and refuses a non-empty container, so it needs its own spec too.
SPECS.rmdir = {
	bool = "pv",
	long = { ["--parents"] = "bool:-p", ["--verbose"] = "bool:-v" },
}
-- `file` used to BE `stat`, which meant `file x` answered a one-line question
-- with eight lines of metadata and accepted stat's -c. It now has its own
-- handler and, like file(1), its own flags: -b drops the leading "path: ".
SPECS.file = { bool = "b" }

-- The parse every handler uses. runCommand has already run this exact call as a
-- pre-dispatch gate, so the error return cannot fire here, re-running it beats
-- threading four values through every handler signature.
local function parse(argv: { string }): ({ [string]: boolean }, { [string]: { string } }, { string })
	local flags, values, operands = partition(argv, SPECS[argv[1]])
	return flags, values, operands
end

-- `luaPattern` used to sit here: a translation layer that took a regex, rewrote
-- the escapes it could map onto Lua patterns, and refused the constructs it
-- could not. It is gone, along with the REGEXISH heuristic and the "grep matches
-- literal text" nudge that existed only to apologise for it. Patterns now go to
-- a real engine in Regex.luau, and `-E` means what it means everywhere else.

-- tr's POSIX character classes. Spelled out rather than derived from Lua's
-- character classes because [:alpha:] is defined over bytes here and a
-- locale-dependent answer would make `tr -d '[:punct:]'` mean different things
-- on different inputs.
local TR_CLASSES: { [string]: string } = {
	alpha = "%a", digit = "%d", alnum = "%w", space = "%s", punct = "%p",
	upper = "%u", lower = "%l", cntrl = "%c", xdigit = "%x", print = "%g%s", graph = "%g",
}

-- Escape sequences tr accepts inside a set. Without these `tr -d '\n'` deleted a
-- backslash and the letter n, two characters that are almost never in the
-- input: so the command reported success and changed nothing.

local function expandTrSet(s: string): string
	local expanded = {}
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		-- [:alpha:] and friends, expanded to every byte in the class.
		local class = s:match("^%[:(%a+):%]", i)
		if class then
			local pattern = TR_CLASSES[class]
			if pattern then
				for code = 0, 255 do
					local char = string.char(code)
					if char:match(pattern) then
						expanded[#expanded + 1] = char
					end
				end
				i += #class + 4
				continue
			end
		end
		if c == "\\" and i < #s then
			local following = s:sub(i + 1, i + 1)
			local mapped = TR_ESCAPES[following]
			if mapped then
				expanded[#expanded + 1] = mapped
				i += 2
				continue
			end
			-- \NNN octal, which is how tr spells a byte with no letter for it.
			local octal = s:match("^(%d%d?%d?)", i + 1)
			if octal then
				expanded[#expanded + 1] = string.char(tonumber(octal, 8) % 256)
				i += 1 + #octal
				continue
			end
		end
		if s:sub(i + 1, i + 1) == "-" and i + 2 <= #s then
			local startC = c:byte()
			local endC = s:sub(i + 2, i + 2):byte()
			for code = startC, endC do
				expanded[#expanded + 1] = string.char(code)
			end
			i = i + 3
		else
			expanded[#expanded + 1] = c
			i = i + 1
		end
	end
	return table.concat(expanded)
end


-- One function per command. A table rather than an elseif chain because the
-- list is the thing that grows, and this way the "unknown command" hint and the
-- alias entries below are derived from it instead of maintained alongside it.
local HANDLERS: { [string]: (any, { string }, string?) -> string } = {}

-- -L and -P differ only where symlinks do. Nothing resolves through an
-- ObjectValue here, so both spellings have the same answer and accepting them is
-- honest rather than a dropped flag.
HANDLERS.pwd = function(self)
	return self:pwd()
end

-- whoami: who is running this, and where.
--
-- Marginal on its own, but it is a reflex command, it was answering "unknown
-- command", and the place ids are genuinely worth having: an unpublished place
-- reports 0, which tells the model up front that anything asset- or
-- DataStore-shaped is going to fail for reasons that have nothing to do with
-- its code.
--
-- Deliberately no username lookup. GetNameFromUserIdAsync is a network round
-- trip, and this command exists to be the cheap one, a name is not worth
-- turning "who am I" into a request that can hang.
--
-- It is NOT unsafe to yield here, which an earlier note in this spot claimed.
-- Tool dispatch runs from onComplete at message_stop, where the stream has
-- already delivered everything and there is no parsing left to stall; `catalog`
-- has yielded there for seconds since it shipped. What a yield does cost is
-- holding one of the six available WebStreamClients open until it returns.
HANDLERS.whoami = function()
	local StudioService = game:GetService("StudioService")
	local ok, userId = pcall(function()
		return StudioService:GetUserId()
	end)
	local who = (ok and userId and userId ~= 0) and tostring(userId) or "not signed in"
	return string.format("user %s\nplace %d  game %d%s\nrunning as a Studio plugin",
		who, game.PlaceId, game.GameId,
		game.PlaceId == 0 and "  (unpublished)" or "")
end

HANDLERS.echo = function(_, argv)
	-- Quoting is already resolved by the tokenizer, so this is also the cheapest
	-- way to see how a line was actually split.
	--
	-- echo parses its own flags rather than going through the spec gate, because
	-- for echo a leading dash is USUALLY data. Running it through the generic
	-- check turned `echo "---"` and `echo -x` into "unsupported flag" errors,
	-- where every other shell prints them. Only a LEADING argument that is
	-- exactly -n/-e/-E, or a combination of those letters, is a flag; the first
	-- argument that is not stops flag parsing for the whole rest of the line.
	local escapes, literal, first = false, false, 2
	while first <= #argv do
		local letters = argv[first]:match("^%-([neE]+)$")
		if not letters then
			break
		end
		escapes = escapes or letters:find("e", 1, true) ~= nil
		literal = literal or letters:find("E", 1, true) ~= nil
		first += 1
	end

	local text = table.concat(argv, " ", first, #argv)
	if escapes and not literal then
		-- -e interprets escapes; -E (the default) leaves them literal.
		text = text:gsub("\\(.)", function(c)
			return TR_ESCAPES[c] or ("\\" .. c)
		end)
	end
	-- -n suppresses the trailing newline. There is no trailing newline on a
	-- returned string here to suppress, so it is accepted and changes nothing
	-- which is the true answer, not a silently dropped flag.
	return text
end

HANDLERS.cd = function(self, argv)
	local _, _, operands = parse(argv)
	if not operands[1] then
		return "cd: requires a path"
	end
	local ok, err = self:cd(operands[1])
	if not ok then
		return fail("cd", err)
	end
	return self:pwd()
end

-- Sort rows for ls. By name unless asked otherwise; -U turns sorting off, which
-- is the only way to see GetChildren() order.
local function lsSort(rows: { any }, flags: { [string]: boolean })
	if flags["-U"] then
		return
	end
	local rank: ((any) -> number)? = nil
	if flags["-S"] then
		rank = function(row)
			return -(Fs.size(row.inst))
		end
	elseif flags["-t"] or flags["-c"] then
		-- An unobserved instance sorts LAST rather than first. It is not "the
		-- oldest", it is unranked, and burying it under the ones we can actually
		-- date is the only placement that does not assert a time we do not have.
		rank = function(row)
			return -(Fs.mtime(row.inst) or -math.huge)
		end
	end
	table.sort(rows, function(a, b)
		if rank then
			local ra, rb = rank(a), rank(b)
			if ra ~= rb then
				return ra < rb
			end
		end
		return a.name < b.name
	end)
	if flags["-r"] then
		-- Reversed afterwards rather than by flipping the comparator, so the name
		-- tiebreak reverses too and `ls -r` is exactly `ls` read backwards.
		for i = 1, #rows // 2 do
			rows[i], rows[#rows - i + 1] = rows[#rows - i + 1], rows[i]
		end
	end
end

-- One row's worth of text, honouring -1/-l/-i/-h/-F/-p/-Q.
local function lsRow(row: any, flags: { [string]: boolean }): string
	local inst = row.inst
	local name = row.name
	if flags["-q"] then
		-- Instance names are free-form and really can hold control characters,
		-- which would otherwise reach the console raw and scramble the listing.
		name = name:gsub("%c", "?")
	end
	if flags["-Q"] then
		name = string.format("%q", name)
	end
	-- -F classifies everything, -p only containers. A script is a FILE here, so
	-- it never takes the "/", it takes "*" when it will actually run.
	if flags["-F"] or flags["-p"] then
		if not isScript(inst) then
			name ..= "/"
		elseif flags["-F"] and Fs.modeBit(inst, "x") then
			name ..= "*"
		end
	end
	if flags["-i"] then
		name = Fs.debugId(inst) .. "  " .. name
	end
	if not flags["-l"] then
		return name
	end

	-- Still no column padding and no "0 children": alignment is for eyes, the
	-- reader here is a model, and on a 200-part listing that padding plus a zero
	-- on every leaf is most of the bytes.
	local size, isBytes = Fs.size(inst)
	local sizeText = ""
	if isScript(inst) then
		-- Lines by default, because "how big is this file" is the question `ls -l`
		-- is asked about code. -h asks for human-readable BYTES specifically, so
		-- it switches the column rather than scaling a line count.
		sizeText = flags["-h"] and string.format("  %s", Fs.humanSize(size))
			or string.format("  %d lines", #splitLines(getSource(inst) or ""))
	elseif size > 0 then
		sizeText = string.format("  %d children", #inst:GetChildren())
	end

	-- The time column only when time was asked about. Ours is unknown for most
	-- instances, and a "-" on every row of every listing is noise nobody reads.
	local timeText = ""
	if flags["-t"] or flags["-c"] then
		local when = Fs.mtime(inst)
		timeText = "  " .. (when and os.date("%H:%M:%S", when) or "-")
	end

	return string.format("%s  %s [%s]%s%s",
		Fs.modeString(inst), name, inst.ClassName, sizeText, timeText)
end

HANDLERS.ls = function(self, argv)
	local flags, _, operands = parse(argv)
	local target, glob = splitGlob(operands[1])
	local matcher = glob and nameMatcher(glob) or nil

	-- -d is about the container itself, not its contents, the only way to
	-- `ls -l` one instance without listing everything inside it. With a glob
	-- there is nothing to descend into anyway, so the ordinary path covers it.
	if flags["-d"] and not glob then
		local inst, err = self:resolve(target)
		if not inst then
			return fail("ls", err)
		end
		return lsRow({ inst = inst, name = target or displayName(inst) }, flags)
	end

	-- find and grep stop at a cap; ls did not, so `ls /Workspace` in a place with
	-- a few thousand parts returned every one of them and only `forModel`'s
	-- 100 000-char cut stopped it, by which point the listing is ~25 000 tokens
	-- that every later turn re-sends. One budget across the whole walk, because
	-- what costs is the size of the tool result, not of any single listing.
	--
	-- The ROOT is exempt. That cap is for a container holding thousands of parts;
	-- the service list is a different animal, the engine bounds it, and every
	-- entry is load-bearing, because a service you cannot see is a whole subtree
	-- you cannot reach. Studio instantiates well over a hundred services, and
	-- rows are sorted before the cut, so `ls /` was dropping the alphabetical
	-- tail: Workspace, starting with W, fell off every single time while find,
	-- tree, stat and cat all still saw it. Deterministic, and invisible unless
	-- you counted.
	local out: { string } = {}
	local budget = (self:resolve(target) == game) and math.huge or MAX_LIST
	local skipped = 0
	local firstDropped: string? = nil
	local emptyLabel: string? = nil

	local function listOne(path: string?, header: boolean): string?
		local rows, err = self:ls(path, matcher)
		if not rows then
			return err
		end
		lsSort(rows, flags)
		if header then
			if #out > 0 then
				out[#out + 1] = ""
			end
			out[#out + 1] = (path or ".") .. ":"
		end
		for _, row in ipairs(rows) do
			if budget <= 0 then
				skipped += 1
				-- Remember WHICH entry the cut started at. A bare "... 23 more"
				-- reads as "the boring tail", naming the first casualty is what
				-- turns it into "Workspace is missing", which is the difference
				-- between a truncation you can reason about and one you cannot.
				firstDropped = firstDropped or row.name
			else
				budget -= 1
				out[#out + 1] = lsRow(row, flags)
			end
		end
		-- -R descends after listing, which is the order bash prints them in.
		if flags["-R"] then
			for _, row in ipairs(rows) do
				if not isScript(row.inst) and #row.inst:GetChildren() > 0 then
					local err2 = listOne(instancePath(row.inst), true)
					if err2 then
						return err2
					end
				end
			end
		end
		if #rows == 0 and not header then
			-- A bare "(empty)" is indistinguishable from "ls silently failed",
			-- which is what sends an agent off probing with `|| echo "no ls
			-- support"`. Naming what was resolved makes a wrong-instance hit
			-- obvious instead: FindFirstChild("ServerStorage") and
			-- GetService("ServerStorage") return different objects the moment
			-- something else in game shares the name.
			local resolved = self:resolve(path)
			emptyLabel = resolved
				and string.format("%s [%s]", instancePath(resolved), resolved.ClassName)
				or tostring(path)
		end
		return nil
	end

	local walkErr = listOne(target, false)
	if walkErr then
		return fail("ls", walkErr)
	end
	if #out == 0 and emptyLabel then
		return string.format("(%s) %s", glob and "no matches" or "empty", emptyLabel)
	end
	if skipped > 0 then
		out[#out + 1] = string.format("… %d more from %q on (narrow it: `ls %s/A*`, or `ls | grep <name>`)",
			skipped, firstDropped or "?", target or ".")
	end
	return table.concat(out, "\n")
end

-- Expand any wildcard operand against its own directory.
--
-- Globbing was previously only wired into `ls`, so `cat *.luau` looked for one
-- instance literally named "*.luau" and reported it missing. cat is the command
-- that actually needs this: grep and find already walk descendants on their own,
-- so `grep foo .` covers what `grep foo *.luau` would have meant.
local function expandGlobs(self: any, operands: { string }): { string }
	local out: { string } = {}
	for _, operand in ipairs(operands) do
		local dir, pattern = splitGlob(operand)
		if not pattern then
			out[#out + 1] = operand
			continue
		end
		local matched = self:ls(dir, nameMatcher(pattern))
		if not matched or #matched == 0 then
			-- Same as bash with nullglob off: an unmatched pattern is passed
			-- through untouched, so the command reports it by name rather than
			-- silently doing nothing.
			out[#out + 1] = operand
		else
			local prefix = (dir and dir ~= "" and dir ~= "/") and (dir .. "/") or (dir == "/" and "/" or "")
			table.sort(matched, function(a, b)
				return a.name < b.name
			end)
			for _, row in ipairs(matched) do
				out[#out + 1] = prefix .. row.name
			end
		end
	end
	return out
end

-- cat's display flags, applied in the order coreutils applies them.
local function catRender(text: string, flags: { [string]: boolean }): string
	local lines = splitLines(text)
	local out: { string } = {}
	local numbered = 0
	local blankRun = 0
	for _, line in ipairs(lines) do
		-- -s squeezes runs of blank lines down to one.
		if line == "" then
			blankRun += 1
			if flags["-s"] and blankRun > 1 then
				continue
			end
		else
			blankRun = 0
		end
		local body = line
		if flags["-T"] or flags["-A"] then
			body = body:gsub("\t", "^I")
		end
		if flags["-v"] or flags["-A"] then
			-- Control characters in caret notation, so a stray \r is visible
			-- rather than silently eating the line when it reaches a console.
			body = body:gsub("%c", function(c)
				return "^" .. string.char(c:byte() + 64)
			end)
		end
		if flags["-E"] or flags["-A"] then
			body ..= "$"
		end
		-- -b numbers only non-blank lines and wins over -n, as it does in cat.
		if flags["-b"] then
			if line ~= "" then
				numbered += 1
				body = string.format("%6d\t%s", numbered, body)
			else
				body = "\t" .. body
			end
		elseif flags["-n"] then
			numbered += 1
			body = string.format("%6d\t%s", numbered, body)
		end
		out[#out + 1] = body
	end
	return table.concat(out, "\n")
end

HANDLERS.cat = function(self, argv, stdin)
	local flags, _, operands = parse(argv)
	-- -e and -t are shorthand, exactly as in cat: -vE and -vT. Expanded here so
	-- catRender only ever has one spelling of each behaviour to check.
	if flags["-e"] then
		flags["-E"], flags["-v"] = true, true
	end
	if flags["-t"] then
		flags["-T"], flags["-v"] = true, true
	end
	-- Any display flag means the source has to be reshaped line by line;
	-- otherwise it is passed through untouched, which keeps the common `cat f`
	-- byte-for-byte identical to the file.
	local plain = not (flags["-n"] or flags["-b"] or flags["-s"] or flags["-E"]
		or flags["-T"] or flags["-A"] or flags["-v"])

	if #operands == 0 and stdin then
		return plain and stdin or catRender(stdin, flags)
	end
	operands = expandGlobs(self, operands)
	if #operands <= 1 then
		local s, err = self:cat(operands[1])
		if not s then
			return fail("cat", err)
		end
		return plain and s or catRender(s, flags)
	end
	-- Real cat concatenates; with several scripts a header is the only way to
	-- tell where one ended.
	local parts: { string } = {}
	for _, operand in ipairs(operands) do
		local s, err = self:cat(operand)
		local body = s and (plain and s or catRender(s, flags)) or ("cat: " .. tostring(err))
		parts[#parts + 1] = string.format("==> %s <==\n%s", operand, body)
	end
	return table.concat(parts, "\n\n")
end

-- stat -c's format specifiers, limited to the fields that actually exist. %U/%G
-- (owner, group) and %y (mtime as a date) are absent on purpose: three of those
-- have no source at all, and inventing a value for a format string is the one
-- place a wrong answer is guaranteed to be believed.
local STAT_FIELDS: { [string]: (Instance) -> string } = {
	n = function(inst) return Fs.displayName(inst) end,
	N = function(inst) return instancePath(inst) end,
	F = function(inst) return inst.ClassName end,
	i = function(inst) return Fs.debugId(inst) end,
	a = function(inst) return Fs.modeString(inst) end,
	s = function(inst) return tostring((Fs.size(inst))) end,
	Y = function(inst) return tostring(Fs.mtime(inst) or 0) end,
}

HANDLERS.stat = function(self, argv)
	local _, values, operands = parse(argv)
	local format = valueOf(values, "-c")
	if format then
		local out: { string } = {}
		for _, path in ipairs(#operands > 0 and operands or { "." }) do
			local target, err = self:resolve(path)
			if not target then
				return fail("stat", err)
			end
			local unknown: string? = nil
			local rendered = format:gsub("%%(.)", function(spec)
				if spec == "%" then
					return "%"
				end
				local field = STAT_FIELDS[spec]
				if not field then
					unknown = unknown or spec
					return ""
				end
				return field(target)
			end)
			if unknown then
				return fail("stat", string.format("%%%s is not a field here — stat knows " ..
					"%%n (name), %%N (path), %%F (class), %%s (size), %%i (debug id), " ..
					"%%a (mode bits), %%Y (observed mtime, 0 if never seen)", unknown))
			end
			out[#out + 1] = rendered
		end
		return table.concat(out, "\n")
	end
	local parts: { string } = {}
	for _, path in ipairs(#operands > 0 and operands or { "." }) do
		local s, err = self:stat(path)
		if not s then
			return fail("stat", err)
		end
		parts[#parts + 1] = s
	end
	return table.concat(parts, "\n\n")
end

-- Text input for the filter commands: a file operand when there is one, piped
-- input otherwise.
--
-- These four used to disagree about the same mistake. `sed f.luau` and
-- `tr a-z A-Z f.luau` errored clearly with "requires piped input"; `sort
-- f.luau` and `uniq f.luau` ignored the operand entirely and emitted nothing,
-- which reads as "the file was empty" rather than "I didn't read your file".
-- Real sort/uniq/sed/tr all take a file argument, so the fix is to accept one
-- rather than to make the error messages agree.
--
-- Declared up here rather than beside its first user: head, tail and wc reach
-- for it too now, and a local defined further down the file is not in scope
-- above it, it would read as a nil global and throw at call time.
local function textInput(self: any, operands: { string }, stdin: string?): (string?, string?)
	local path = operands[1]
	if path then
		local target, err = self:resolve(path)
		if not target then return nil, err end
		local source = getSource(target)
		if not source then return nil, "not a script: " .. instancePath(target) end
		return source, nil
	end
	if stdin then return stdin, nil end
	return nil, "requires a file operand or piped input"
end

-- The same thing for EVERY operand, not just the first. head, tail and wc all
-- took one path and dropped the rest on the floor, so `head a.luau b.luau`
-- returned the first file's lines and said nothing about the second, a partial
-- answer shaped exactly like a complete one.
export type TextInput = { path: string?, text: string }

local function inputs(self: any, operands: { string }, stdin: string?): ({ TextInput }?, string?)
	if #operands == 0 then
		if stdin then
			return { { path = nil, text = stdin } }, nil
		end
		return nil, "requires a file operand or piped input"
	end
	local out: { TextInput } = {}
	for _, path in ipairs(operands) do
		local target, err = self:resolve(path)
		if not target then
			return nil, err
		end
		local source = getSource(target)
		if not source then
			return nil, "not a script: " .. instancePath(target)
		end
		out[#out + 1] = { path = instancePath(target), text = source }
	end
	return out, nil
end

-- Join per-file results with the `==> path <==` header bash prints whenever
-- there is more than one file, and never for a single file or a stream, where
-- it would be noise. -v forces it on, -q forces it off.
local function joinFiles(parts: { { path: string?, body: string } },
	force: boolean?, quiet: boolean?): string
	local out: { string } = {}
	if quiet or (#parts <= 1 and not force) then
		for _, part in ipairs(parts) do
			out[#out + 1] = part.body
		end
		return table.concat(out, "\n")
	end
	for _, part in ipairs(parts) do
		out[#out + 1] = string.format("==> %s <==\n%s", part.path or "standard input", part.body)
	end
	return table.concat(out, "\n\n")
end

-- head/tail's -n carries a sign in bash: `head -n -5` is "all but the last 5",
-- `tail -n +5` is "from line 5 to the end". Losing the sign turns either into a
-- plain count, which returns real lines from the wrong end of the file.
local function lineSpec(text: string?): (number?, string)
	local sign, digits = (text or ""):match("^([%+%-]?)(%d+)$")
	if not digits then
		return nil, ""
	end
	return tonumber(digits), sign
end

-- `-c` counts BYTES, not lines. It used to land in the flag set that nobody
-- read, so `head -c 50 f` silently ran as `head f` and returned ten lines
-- roughly 1500 characters to someone probing a large file specifically to avoid
-- flooding their context. A silent wrong answer on the one command whose whole
-- purpose is to limit output.
-- head and tail differ only in which end they cut from, so they are one function
-- with a flag. Both used to be implemented TWICE, once in Terminal for a file
-- operand and once here for piped input, which is how they came to disagree
-- about -c and about multiple operands.
local function headTail(self: any, cmd: string, argv: { string }, stdin: string?): string
	local flags, values, operands = parse(argv)
	-- Split the operands: the first bare number is the count (`head -20 x`,
	-- `head x 20`), everything else is a file. Done here rather than through
	-- takeCount because that returns ONE path and drops the rest, which is
	-- exactly how `head a.luau b.luau` came to read only the first.
	local paths: { string } = {}
	local bare: number? = nil
	for _, operand in ipairs(operands) do
		-- Zero is a COUNT, not a path. `n > 0` here meant `head -0` fell through
		-- to the path list and came back "no child named -0", while -1 and up
		-- worked: the one number where asking for nothing is a real request.
		local flagForm = operand:match("^%-(%d+)$")
		local n = tonumber(flagForm or operand)
		if n and n >= 0 and not bare then
			bare = math.floor(n)
		else
			paths[#paths + 1] = operand
		end
	end

	local byteMode = flags["-c"] == true
	local countFlag = byteMode and "-c" or "-n"
	local count, sign = lineSpec(valueOf(values, countFlag))
	if flags[countFlag] and not count then
		return fail(cmd, string.format("%s needs a number, as `%s %s 200 file`",
			countFlag, cmd, countFlag))
	end
	count = count or bare or 10

	local files, err = inputs(self, expandGlobs(self, paths), stdin)
	if not files then
		return fail(cmd, err)
	end

	local parts: { { path: string?, body: string } } = {}
	for _, file in ipairs(files) do
		local body: string
		if byteMode then
			body = cmd == "tail" and file.text:sub(-count) or file.text:sub(1, count)
		else
			local all = splitLines(file.text)
			local from, to
			if cmd == "head" then
				-- `head -n -5`: everything except the last five.
				to = sign == "-" and #all - count or math.min(count, #all)
				from = 1
			else
				-- `tail -n +5`: from line five to the end.
				from = sign == "+" and count or math.max(1, #all - count + 1)
				to = #all
			end
			body = (from > to or to < 1) and "" or table.concat(all, "\n", math.max(1, from), to)
		end
		parts[#parts + 1] = { path = file.path, body = body }
	end
	return joinFiles(parts, flags["-v"], flags["-q"])
end

HANDLERS.head = function(self, argv, stdin)
	return headTail(self, "head", argv, stdin)
end

HANDLERS.tail = function(self, argv, stdin)
	return headTail(self, "tail", argv, stdin)
end

-- wc returned "238 lines", prose, not a number, so it composed with nothing and
-- `for f in ...; wc -l < $f` produced a column of sentences. The flags were
-- ignored entirely on a file operand, which is the same shape of bug as head -c.
--
-- Asked for one count, you get one number. Asked for nothing in particular, you
-- get all three labelled, because that is a human reading /sh and there is no
-- second field for them to mistake it for.
HANDLERS.wc = function(self, argv, stdin)
	local flags, _, operands = parse(argv)
	local files, inputErr = inputs(self, expandGlobs(self, operands), stdin)
	if not files then
		-- Not a script. A container's only size is its children, which is a real
		-- answer to `wc /Workspace` and not one wc can compute from text.
		local target = operands[1] and self:resolve(operands[1])
		if target and not getSource(target) then
			return string.format("%d children", #target:GetChildren())
		end
		return fail("wc", inputErr)
	end

	-- One row per file plus a total, the way wc does it. Asked for one count you
	-- get one number: it used to return "238 lines", prose, which composes with
	-- nothing, so `wc -l < f` produced a sentence where a number was expected.
	local function row(text: string): (number, number, number, number, number)
		local lines = #splitLines(text)
		local words = select(2, text:gsub("%S+", ""))
		-- -m counts CHARACTERS, which is not #text the moment a comment holds a
		-- non-ASCII character. utf8.len returns nil on malformed input, and bytes
		-- are the honest fallback there.
		local chars = utf8.len(text) or #text
		local longest = 0
		for _, line in ipairs(splitLines(text)) do
			longest = math.max(longest, #line)
		end
		return lines, words, #text, chars, longest
	end

	local function render(lines: number, words: number, bytes: number,
		chars: number, longest: number): string
		local counts: { string } = {}
		if flags["-l"] then counts[#counts + 1] = tostring(lines) end
		if flags["-w"] then counts[#counts + 1] = tostring(words) end
		if flags["-c"] then counts[#counts + 1] = tostring(bytes) end
		if flags["-m"] then counts[#counts + 1] = tostring(chars) end
		if flags["-L"] then counts[#counts + 1] = tostring(longest) end
		if #counts > 0 then
			return table.concat(counts, " ")
		end
		-- Nothing asked for in particular: all three labelled, because that is a
		-- human reading /sh and there is no second field to mistake it for.
		return string.format("%d lines  %d words  %d bytes", lines, words, bytes)
	end

	local out: { string } = {}
	local totals = { 0, 0, 0, 0, 0 }
	for _, file in ipairs(files) do
		local lines, words, bytes, chars, longest = row(file.text)
		totals[1] += lines
		totals[2] += words
		totals[3] += bytes
		totals[4] += chars
		totals[5] = math.max(totals[5], longest)
		local text = render(lines, words, bytes, chars, longest)
		out[#out + 1] = #files > 1 and (text .. "  " .. tostring(file.path)) or text
	end
	if #files > 1 then
		out[#out + 1] = render(totals[1], totals[2], totals[3], totals[4], totals[5]) .. "  total"
	end
	return table.concat(out, "\n")
end

HANDLERS.tree = function(self, argv)
	local flags, values, operands = parse(argv)
	local target, depth = takeCount(operands)
	depth = numberOf(values, "-L") or depth
	local s, err = self:tree(target, depth, {
		dirsOnly = flags["-d"],
		fullPath = flags["-f"],
		classify = flags["-F"],
		dirsFirst = flags["--dirsfirst"],
		include = valueOf(values, "-P"),
		exclude = valueOf(values, "-I"),
	})
	return s or fail("tree", err)
end

HANDLERS.du = function(self, argv)
	local flags, values, operands = parse(argv)
	local target, err = self:resolve(operands[1])
	if not target then
		return fail("du", err)
	end
	local maxDepth = numberOf(values, "-d") or (flags["-s"] and 0 or 1)

	-- Size is descendant count, or source bytes for a script, the same measure
	-- `ls -l` and `find -size` use, so the three cannot disagree about one
	-- instance. -h only scales the byte form: "1.2K descendants" is not a unit.
	local function render(size: number, isBytes: boolean): string
		if flags["-h"] and isBytes then
			return Fs.humanSize(size)
		end
		return tostring(size)
	end

	local lines: { string } = {}
	local total = 0
	local function walk(inst: Instance, depth: number): number
		-- GetDescendants already gives the subtree size, so the recursion below is
		-- only for the rows that get PRINTED. Recursing past maxDepth as well made
		-- a bare `du /` walk the whole DataModel to produce one line of output.
		local size = #inst:GetDescendants() + 1
		if depth <= maxDepth then
			-- -a lists every instance; without it only containers are reported,
			-- which is what makes du a summary rather than a second `find`.
			if flags["-a"] or not isScript(inst) then
				local own, isBytes = Fs.size(inst)
				lines[#lines + 1] = string.format("%s\t%s",
					render(isScript(inst) and own or size, isScript(inst) and isBytes),
					instancePath(inst))
			end
			for _, child in ipairs(inst:GetChildren()) do
				walk(child, depth + 1)
			end
		end
		return size
	end

	-- Children first, deepest-last, then the target itself, du's own order, and
	-- the reason the total lands at the bottom where it is read.
	for _, child in ipairs(target:GetChildren()) do
		total += walk(child, 1)
	end
	-- Sorted heaviest-first, because the question du answers is always "where is
	-- the bulk of this". Stable on the path so two runs agree.
	table.sort(lines, function(a, b)
		local na = tonumber(a:match("^(%d+)")) or 0
		local nb = tonumber(b:match("^(%d+)")) or 0
		if na ~= nb then
			return na > nb
		end
		return a < b
	end)
	if flags["-c"] or not flags["-s"] then
		lines[#lines + 1] = string.format("%d\ttotal", total + 1)
	end
	return table.concat(lines, "\n")
end

-- find's numeric argument: `+N` is more than N, `-N` is fewer than N, a bare N
-- is exactly N. nil when the argument is not a number at all, so the caller can
-- refuse rather than silently treating a typo as zero.
local function findCompare(arg: string?): ((number) -> boolean)?
	local sign, digits = (arg or ""):match("^([%+%-]?)(%d+)$")
	local n = tonumber(digits)
	if not n then
		return nil
	end
	if sign == "+" then
		return function(v) return v > n end
	elseif sign == "-" then
		return function(v) return v < n end
	end
	return function(v) return v == n end
end

-- -size takes a unit suffix: c bytes, k KiB, M MiB, G GiB. A BARE number is
-- bytes for a script and DESCENDANTS for anything else, because those are the
-- two things `Fs.size` can actually measure. GNU's bare number means 512-byte
-- blocks; there are no blocks here, and inventing them would make every bare
-- -size answer wrong by a factor of 512.
local SIZE_UNITS: { [string]: number } = { c = 1, k = 1024, M = 1024 * 1024, G = 1024 * 1024 * 1024 }

-- One clause of a find expression: does this instance qualify?
type FindTest = (Instance) -> boolean

-- Tests that take a value, so the parser knows to consume the next argument.
local FIND_VALUE_TESTS: { [string]: boolean } = {
	["-name"] = true, ["-iname"] = true, ["-path"] = true, ["-ipath"] = true,
	["-regex"] = true, ["-iregex"] = true, ["-type"] = true, ["-size"] = true,
	["-newer"] = true, ["-mmin"] = true, ["-mtime"] = true, ["-inum"] = true,
	["-perm"] = true, ["-maxdepth"] = true, ["-mindepth"] = true,
}

-- Named rather than skipped. Silently ignoring -maxdepth meant returning the
-- whole subtree to someone who asked for three levels, with nothing in the
-- output to say so, and the same is true of every filter below.
local FIND_UNSUPPORTED: { [string]: string } = {
	["-exec"] = "runs a command per result, and there is no process to run — " ..
		"use the `run` tool, or pipe find's output into grep",
	["-execdir"] = "runs a command per result; use the `run` tool",
	["-ok"] = "prompts before running a command, and there is nothing to prompt",
	["-user"] = "matches the owning user, and an Instance has no owner — nothing " ..
		"in the DataModel records who made it",
	["-group"] = "matches the owning group, and an Instance has no owner or group",
	["-nouser"] = "matches files with no owner, and no Instance has one",
	["-follow"] = "follows symlinks, and nothing resolves through an ObjectValue — see `ln`",
	["-xdev"] = "stays on one filesystem, and there is only one DataModel",
	["-mount"] = "stays on one filesystem, and there is only one DataModel",
	["-print0"] = "separates results with NULs, and everything here is line-oriented text",
	["-atime"] = "matches access time, and nothing here records a read",
	["-amin"] = "matches access time, and nothing here records a read",
}

HANDLERS.find = function(self, argv)
	-- Two call shapes reach here: the native `find <pattern> [path]` and the GNU
	-- `find <path> -name <pattern>`. -iname is the same as -name, since matching
	-- is case-insensitive either way.
	--
	-- The expression is a flat OR of AND-groups, which is what `a -o b`, `a b`
	-- and `! a` need and as much grammar as find is ever written with here. A
	-- real parenthesised parser is the upgrade path if that stops being true.
	local groups: { { FindTest } } = { {} }
	local bare: { string } = {}
	local minDepth: number? = nil
	local maxDepth: number? = nil
	local deleting = false
	local negateNext = false
	local now = os.time()

	local function add(test: FindTest)
		local negated = negateNext
		negateNext = false
		local group = groups[#groups]
		group[#group + 1] = negated and function(inst)
			return not test(inst)
		end or test
	end

	local i = 2
	while i <= #argv do
		local arg = argv[i]
		local value: string? = nil
		if FIND_VALUE_TESTS[arg] then
			value = argv[i + 1]
			i += 1
			if value == nil then
				return fail("find", arg .. " needs a value")
			end
		end

		if arg == "-name" or arg == "-iname" then
			-- Matched against the DISPLAYED name as well as the real one. `ls`
			-- prints scripts as `Main.luau`, so a model that read a listing will
			-- reasonably search for `*.luau`, and no instance name has ever
			-- contained that suffix, so matching only .Name meant the most natural
			-- search in the whole harness silently returned nothing.
			local matches = nameMatcher(value :: string)
			add(function(inst)
				return matches(inst.Name) or matches(displayName(inst))
			end)
		elseif arg == "-path" or arg == "-ipath" then
			local matches = nameMatcher(value :: string)
			add(function(inst)
				return matches(instancePath(inst))
			end)
		elseif arg == "-regex" or arg == "-iregex" then
			-- GNU find anchors -regex to the WHOLE path, which is the part people
			-- get wrong: `-regex 'Main'` matches nothing, `-regex '.*/Main'` does.
			-- Matching unanchored here would quietly accept both and disagree with
			-- every other find on earth.
			local program, compileErr = Regex.compile("^(?:" .. (value :: string) .. ")$",
				{ ere = true, ignoreCase = arg == "-iregex" })
			if not program then
				return fail("find", compileErr)
			end
			add(function(inst)
				return program:find(instancePath(inst)) ~= nil
			end)
		elseif arg == "-type" then
			-- `-type f` and `-type d` are the reflex; LuaSourceContainer is the
			-- real superclass of Script/LocalScript/ModuleScript, so "f" has an
			-- exact answer.
			--
			-- "d" does not. Folder is the obvious analogue and the wrong one: a
			-- place is organised with Models, Tools, services and Configurations
			-- just as often, and every Instance can hold children, so `-type d`
			-- matching Folder alone reported nothing at all in most real places.
			-- In a filesystem metaphor the honest split is the one that already
			-- exists: a script is a file, everything else you can descend into.
			local class = value :: string
			local negate = false
			if class == "f" then
				class = "LuaSourceContainer"
			elseif class == "d" then
				class, negate = "LuaSourceContainer", true
			end
			if not Props.classExists(class) then
				return fail("find", string.format(
					"not a class name: %s — try -type f (scripts), -type d (folders), " ..
						"or a real ClassName like Part, Tool, RemoteEvent", class))
			end
			add(function(inst)
				return inst:IsA(class) ~= negate
			end)
		elseif arg == "-size" then
			local text = value :: string
			local unit = SIZE_UNITS[text:sub(-1)]
			local compare = findCompare(unit and text:sub(1, -2) or text)
			if not compare then
				return fail("find", string.format(
					"-size takes a number with an optional unit, as `-size +10k` — got %q " ..
						"(c bytes, k KiB, M MiB, G GiB; a bare number is bytes for a script " ..
						"and descendants for anything else)", text))
			end
			add(function(inst)
				local size, isBytes = Fs.size(inst)
				if unit then
					-- A unit is a statement about bytes, so a container, whose
					-- size is a count, cannot satisfy it.
					return isBytes and compare(size / unit)
				end
				return compare(size)
			end)
		elseif arg == "-newer" then
			local other, resolveErr = self:resolve(value)
			if not other then
				return fail("find", resolveErr)
			end
			local reference = Fs.mtime(other)
			if not reference then
				return fail("find", string.format(
					"-newer %s: no observed modification time for it — this plugin only " ..
						"knows about changes since it loaded, so there is nothing to " ..
						"compare against", value))
			end
			add(function(inst)
				local when = Fs.mtime(inst)
				return when ~= nil and when > reference
			end)
		elseif arg == "-mmin" or arg == "-mtime" then
			local compare = findCompare(value)
			if not compare then
				return fail("find", arg .. " needs a number, as `" .. arg .. " -10`")
			end
			local scale = arg == "-mmin" and 60 or 86400
			add(function(inst)
				local when = Fs.mtime(inst)
				-- An instance with no observed time matches neither `-mmin -10`
				-- nor `-mmin +10`. It is unranked, not old.
				return when ~= nil and compare((now - when) / scale)
			end)
		elseif arg == "-inum" then
			local wanted = value :: string
			add(function(inst)
				return Fs.debugId(inst) == wanted
			end)
		elseif arg == "-perm" then
			local wanted = value :: string
			if wanted:match("^%-?%d+$") then
				return fail("find", "-perm takes mode letters here, not octal — 755 encodes " ..
					"user/group/other and there is no owner to give those three digits a " ..
					"meaning. Use x (runs), a (Archivable) or l (Locked).")
			end
			local letters = wanted:gsub("^[%-/]", "")
			for letter in letters:gmatch(".") do
				if not ("xal"):find(letter, 1, true) then
					return fail("find", string.format(
						"-perm %q: unknown mode letter %q — x (runs), a (Archivable), l (Locked)",
						wanted, letter))
				end
			end
			add(function(inst)
				for letter in letters:gmatch(".") do
					if Fs.modeBit(inst, letter) ~= true then
						return false
					end
				end
				return true
			end)
		elseif arg == "-empty" then
			add(function(inst)
				if #inst:GetChildren() > 0 then
					return false
				end
				local source = getSource(inst)
				return source == nil or source == ""
			end)
		elseif arg == "-maxdepth" or arg == "-mindepth" then
			local n = tonumber(value)
			if not n then
				return fail("find", arg .. " needs a number")
			end
			if arg == "-maxdepth" then
				maxDepth = n
			else
				minDepth = n
			end
		elseif arg == "-not" or arg == "!" then
			negateNext = not negateNext
		elseif arg == "-o" or arg == "-or" then
			groups[#groups + 1] = {}
		elseif arg == "-a" or arg == "-and" then
			-- Implicit already; accepted so writing it out is not an error.
		elseif arg == "-print" then
			-- The default action, and printing is all this find does.
		elseif arg == "-delete" then
			deleting = true
		elseif FIND_UNSUPPORTED[arg] then
			return fail("find", arg .. " " .. FIND_UNSUPPORTED[arg])
		elseif arg:sub(1, 1) == "-" and #arg > 1 and not arg:match("^%-%d") then
			return fail("find", string.format("%s is not supported — find takes -name, " ..
				"-iname, -path, -regex, -type, -size, -empty, -perm, -inum, -newer, " ..
				"-mmin, -mtime, -maxdepth, -mindepth, -not, -o and -delete", arg))
		else
			bare[#bare + 1] = arg
		end
		i += 1
	end

	-- `find / -type f` has no name at all, and `find Handler` has no path, so
	-- the bare operands are classified by shape rather than position: a leading
	-- / or a bare . is unambiguously a root, anything else is the pattern.
	local pattern: string? = nil
	local root: string? = nil
	for _, arg in ipairs(bare) do
		if not root and (arg:sub(1, 1) == "/" or arg == "." or arg == "..") then
			root = arg
		elseif not pattern then
			pattern = arg
		elseif not root then
			root = arg
		end
	end
	if pattern then
		local matches = nameMatcher(pattern)
		add(function(inst)
			return matches(inst.Name) or matches(displayName(inst))
		end)
	end

	-- A bare `find` would otherwise accept everything from the cwd, which at /
	-- means walking every descendant of the DataModel for nothing.
	local total = 0
	for _, group in ipairs(groups) do
		total += #group
	end
	if total == 0 and not minDepth and not maxDepth then
		return fail("find", "requires a pattern, a path or a test")
	end

	local function test(inst: Instance): boolean
		for _, group in ipairs(groups) do
			local all = true
			for _, one in ipairs(group) do
				if not one(inst) then
					all = false
					break
				end
			end
			-- An empty group is the `-o` with nothing after it; it must not match
			-- everything, which is what an all-true fold over zero tests gives.
			if all and #group > 0 then
				return true
			end
		end
		return false
	end

	local found, err = self:find(root, test, { minDepth = minDepth, maxDepth = maxDepth })
	if not found then
		return fail("find", err)
	end
	if #found == 0 then
		return "no matches"
	end

	if deleting then
		-- Deepest first, so removing a parent cannot invalidate a child still on
		-- the list. Destroy() takes the subtree with it.
		table.sort(found, function(a, b)
			return #instancePath(a) > #instancePath(b)
		end)
		local removed: { string } = {}
		for _, inst in ipairs(found) do
			if inst.Parent then
				local path = instancePath(inst)
				local _, removeErr = self:remove(path)
				removed[#removed + 1] = removeErr and ("find: " .. tostring(removeErr))
					or ("removed " .. path)
			end
		end
		return table.concat(removed, "\n")
	end

	local lines: { string } = {}
	for _, inst in ipairs(found) do
		lines[#lines + 1] = instancePath(inst) .. "  [" .. inst.ClassName .. "]"
	end
	local skipped = (found :: any).skipped
	if skipped then
		lines[#lines + 1] = string.format("… %d more matches (narrow the path or the pattern)",
			skipped)
	end
	return table.concat(lines, "\n")
end

HANDLERS.which = function(self, argv)
	local flags, _, operands = parse(argv)
	local name = operands[1]
	if not name or name == "" then
		return "which: requires a name"
	end
	-- `which` answers "what runs when I type this", so the command table is the
	-- only correct place to look first. It used to go straight to find(), which
	-- searched the DataModel for an INSTANCE named "grep" and reported whichever
	-- unrelated thing it happened to hit, an answer that looked authoritative
	-- and was never right for the question actually being asked.
	if HANDLERS[name] then
		return name .. ": shell builtin"
	end
	if isSeparateTool(name) then
		return name .. ": separate tool, not a shell command"
	end
	local why = UNSUPPORTED[name]
	if why then
		return fail("which", name .. ": " .. why)
	end
	-- Not a command. Locating an instance by that name is the only other thing
	-- the word could mean here, so keep it, just no longer as the first answer.
	local matches = nameMatcher(name)
	local found, err = self:find(operands[2], function(inst)
		return matches(inst.Name) or matches(displayName(inst))
	end)
	if not found then
		return fail("which", err)
	end
	if #found == 0 then
		return fail("which", name .. ": not a command, and no instance by that name")
	end
	-- -a lists every match; without it which answers with the first, the way it
	-- reports the first thing on the PATH.
	local out: { string } = {}
	for _, inst in ipairs(found) do
		out[#out + 1] = instancePath(inst)
		if not flags["-a"] then
			break
		end
	end
	return table.concat(out, "\n")
end

-- Render hits: the path once per file, then `N: text` for a match and `N- text`
-- for a context line, with `--` between non-adjacent runs, grep's own
-- separators. The path is printed once for the reason ripgrep does it: DataModel
-- paths are deep, a 40-hit grep across 6 scripts spends ~430 characters on paths
-- this way against ~1800 flat, and a tool result is re-sent every remaining turn.
local function formatHits(hits: { any }, showPath: boolean, showLines: boolean, gapped: boolean): string
	local out: { string } = {}
	local currentPath: string? = nil
	local previousLine: number? = nil
	local indent = showPath and "  " or ""
	for _, hit in ipairs(hits) do
		if showPath and hit.path ~= currentPath then
			if #out > 0 then
				out[#out + 1] = ""
			end
			out[#out + 1] = hit.path
			currentPath = hit.path
			previousLine = nil
		end
		-- Only when context was asked for. Without -A/-B/-C every emitted line is
		-- a match, and a `--` between two of them says a group ended where none
		-- began: grep prints the separator between CONTEXT groups, not hits.
		if gapped and previousLine and hit.line > previousLine + 1 then
			out[#out + 1] = indent .. "--"
		end
		if showLines then
			out[#out + 1] = string.format("%s%d%s %s", indent, hit.line,
				hit.match and ":" or "-", hit.text)
		else
			out[#out + 1] = indent .. hit.text
		end
		previousLine = hit.line
	end
	return table.concat(out, "\n")
end

HANDLERS.grep = function(self, argv, stdin)
	local flags, values, operands = parse(argv)
	-- A non-numeric count would otherwise fall back to 0 and quietly print no
	-- context at all, which reads as "there was none" rather than "I could not
	-- read your argument".
	for _, flag in ipairs({ "-A", "-B", "-C", "-m" }) do
		if flags[flag] and not numberOf(values, flag) then
			return fail("grep", string.format("%s needs a number, as `%s 3` or `%s3`",
				flag, flag, flag))
		end
	end
	-- -C is both sides; -A only after, -B only before. Given together the last
	-- one written wins per side, as it does in grep.
	local context = numberOf(values, "-C")
	local before = numberOf(values, "-B") or context or 0
	local after = numberOf(values, "-A") or context or 0

	-- -e names a pattern explicitly, which is the only way to search for one
	-- that starts with a dash, and it repeats. It used to be read as a synonym
	-- for -E, so `grep -e '-foo' f` was not merely unsupported, it turned the
	-- next operand into the pattern and searched for the wrong thing.
	local patterns: { string } = values["-e"] or {}
	local firstOperand = 1
	if #patterns == 0 then
		local pattern = operands[1]
		if not pattern or pattern == "" then
			return fail("grep", "requires a pattern")
		end
		patterns = { pattern }
		firstOperand = 2
	end
	local path = operands[firstOperand]

	-- The dialect, exactly as the real tools define it: plain grep is BRE, -E and
	-- egrep are ERE, -F and fgrep are fixed strings, -P is ERE plus the
	-- extensions the engine carries anyway.
	--
	-- egrep and fgrep are DEFINITIONS, not aliases that happen to share a handler.
	-- Sharing the function meant `egrep '[0-9]'` searched for those six characters
	-- literally and reported no matches, which reads as "there are no digits
	-- here". The invoked name is the only thing that tells them apart.
	local invoked = argv[1]
	local literal = flags["-F"] or invoked == "fgrep"
	-- An escaped literal is only safe as ERE: Regex.escape writes `\(` and `\{`,
	-- which are literal parens and braces in ERE but the GROUP and INTERVAL
	-- metacharacters in BRE. Compiling an escaped string as BRE would turn the
	-- escaping into syntax, which is the opposite of what -F asks for.
	local ere = literal or flags["-E"] or flags["-P"] or invoked == "egrep"
	local ignoreCase = flags["-i"] or false

	-- One builder, used for the real search and for the case-insensitive retry
	-- below. They were written out twice and the retry forgot -w/-x, so a failed
	-- `grep -w Foo` could report "3 with grep -i" from matches that -w would have
	-- rejected: a hint pointing at a search that also finds nothing.
	local function compileAll(caseInsensitive: boolean): ({ any }?, string?)
		local out: { any } = {}
		for index, pattern in ipairs(patterns) do
			-- -w and -x WRAP the pattern, so a fixed-string search becomes a
			-- pattern and the literal has to be escaped first, otherwise
			-- `-w game.Workspace` would start matching `gameXWorkspace`.
			--
			-- The wrapper is written in the SAME dialect as the body. Wrapping a
			-- BRE body in ERE syntax silently reinterprets it: `a\+` is a literal
			-- plus in ERE and one-or-more `a` in BRE, so a mixed-dialect string is
			-- a different search from the one that was asked for.
			local source = literal and Regex.escape(pattern) or pattern
			local open, close = "(?:", ")"
			if not ere then
				-- BRE has no non-capturing group, and the extra capture is harmless
				-- because grep never reads captures back.
				open, close = "\\(", "\\)"
			end
			if flags["-x"] then
				source = "^" .. open .. source .. close .. "$"
			elseif flags["-w"] then
				source = "\\b" .. open .. source .. close .. "\\b"
			end
			local program, compileErr = Regex.compile(source,
				{ ere = ere, ignoreCase = caseInsensitive })
			if not program then
				return nil, compileErr
			end
			out[index] = program
		end
		return out, nil
	end

	local programs, compileErr = compileAll(ignoreCase)
	if not programs then
		return fail("grep", compileErr)
	end

	local opts = {
		-- Case-SENSITIVE by default, which is what grep means everywhere else.
		-- Both sides used to be lowercased unconditionally, so a search for
		-- `Humanoid` also returned `humanoid` and there was no way to ask for the
		-- strict form, a wrong answer that looks exactly like a right one.
		invert = flags["-v"] or false,
		only = flags["-o"] or false,
		before = before,
		after = after,
		limit = numberOf(values, "-m"),
	}

	-- Counting and listing run off the hits, so they are shared between the piped
	-- and the walked path, which had drifted before, with -c working on one and
	-- not the other.
	local function countMatches(hits: { any }): number
		local matches = 0
		for _, hit in ipairs(hits) do
			if hit.match then
				matches += 1
			end
		end
		return matches
	end

	-- Piped in: filter the stream. A path operand still wins, the way it does in
	-- a shell: `grep x file` ignores stdin.
	if stdin and not path then
		-- One pcall for the whole stream: the only thing that throws is the
		-- engine's step budget, and a pattern too expensive for one line is too
		-- expensive for all of them.
		local streamOk, hits = pcall(Fs.grepLines, splitLines(stdin), programs, opts)
		if not streamOk then
			return fail("grep", Regex.isBudget(hits)
				and "that pattern is too expensive to run — anchor it, or replace a " ..
					"nested quantifier like (a+)+ with a single one"
				or tostring(hits))
		end
		local matches = countMatches(hits)
		if flags["-q"] then
			-- Nothing on stdout; the answer is the exit status, which is what `&&`
			-- reads. Silence with a false status is the whole point of -q.
			if matches == 0 then
				failed = true
			end
			return ""
		end
		if flags["-c"] then
			return tostring(matches)
		end
		-- Line numbers of a stream are the stream's, not a file's, so they are
		-- only worth printing when asked for.
		return #hits > 0
			and formatHits(hits, false, flags["-n"] == true, before + after > 0)
			or "no matches"
	end

	local scope = {
		include = valueOf(values, "--include") and nameMatcher(valueOf(values, "--include") :: string) or nil,
		exclude = valueOf(values, "--exclude") and nameMatcher(valueOf(values, "--exclude") :: string) or nil,
	}
	local hits, err = self:grep(programs, path, opts, scope)
	if not hits then
		-- -s is grep's "suppress messages about unreadable files". A path that
		-- does not resolve is exactly that case, so it becomes a silent miss.
		if flags["-s"] then
			return ""
		end
		return fail("grep", err)
	end
	local matches = countMatches(hits)

	if flags["-q"] then
		if matches == 0 then
			failed = true
		end
		return ""
	end
	if flags["-L"] then
		-- Files WITHOUT a match, which cannot be read off the hit list, it only
		-- knows about files that had one. The scope has to be walked again to
		-- know what was searched and came back empty.
		local withMatch: { [string]: boolean } = {}
		for _, hit in ipairs(hits) do
			if hit.match then
				withMatch[hit.path] = true
			end
		end
		local target, resolveErr = self:resolve(path)
		if not target then
			return flags["-s"] and "" or fail("grep", resolveErr)
		end
		local searched = target:GetDescendants()
		table.insert(searched, 1, target)
		local out: { string } = {}
		for _, inst in ipairs(searched) do
			if getSource(inst) and not withMatch[instancePath(inst)] then
				out[#out + 1] = instancePath(inst)
			end
		end
		return table.concat(out, "\n")
	end

	if #hits == 0 then
		if flags["-c"] then
			return "0"          -- a count, since that is what was asked for
		end
		-- The nudge that used to live here explained that grep matched literal
		-- text and pointed at -E. Both halves are gone: plain grep is BRE now, so
		-- a pattern that looks like a regex IS one, and there is nothing to
		-- explain. An honest "no matches" is the whole answer.
		--
		-- grep is case-SENSITIVE, and the failure that hides behind a clean "no
		-- matches" is a search that would have hit with -i. Retrying costs one
		-- extra walk, and only ever on a search that already found nothing.
		if not flags["-i"] then
			local insensitive = compileAll(true)
			local found = insensitive and self:grep(insensitive, path,
				{ invert = opts.invert }, scope)
			if found and #found > 0 then
				return string.format("no matches — %d with `grep -i` (grep is case-sensitive)",
					#found)
			end
		end
		return "no matches"
	end

	if flags["-c"] then
		return tostring(matches)
	end
	if flags["-l"] then
		local seen: { [string]: boolean } = {}
		local paths: { string } = {}
		for _, hit in ipairs(hits) do
			if hit.match and not seen[hit.path] then
				seen[hit.path] = true
				paths[#paths + 1] = hit.path
			end
		end
		return table.concat(paths, "\n")
	end

	-- -h drops the path header, -H forces it. The default prints it, because a
	-- match with no path is unusable when the search covered a whole subtree.
	local showPath = not flags["-h"]
	local body = formatHits(hits, showPath, true, before + after > 0)
	local skipped = (hits :: any).skipped
	if skipped then
		body ..= string.format("\n… %d more matches (narrow the path or the pattern)", skipped)
	end
	return body
end

-- The part of a line sort actually compares. -k picks a field, -t says what
-- separates them, -b drops leading blanks, -f folds case. Written once because
-- sort and uniq both need "the comparable part of this line" and their two
-- answers drifting would make `sort | uniq` disagree with itself.
local function sortKey(line: string, flags: { [string]: boolean },
	values: { [string]: { string } }): string
	local key = line
	local field = valueOf(values, "-k")
	if field then
		local separator = valueOf(values, "-t")
		local parts: { string } = {}
		if separator and separator ~= "" then
			-- Plain split, so a separator like "." is not read as a pattern.
			local from = 1
			while true do
				local at = key:find(separator, from, true)
				if not at then
					parts[#parts + 1] = key:sub(from)
					break
				end
				parts[#parts + 1] = key:sub(from, at - 1)
				from = at + #separator
			end
		else
			for word in key:gmatch("%S+") do
				parts[#parts + 1] = word
			end
		end
		-- `-k 2,3` is a range; the start field alone is the common form.
		local first = tonumber(field:match("^(%d+)") or "") or 1
		local last = tonumber(field:match(",(%d+)") or "") or #parts
		key = table.concat(parts, separator or " ", math.min(first, #parts + 1),
			math.min(last, #parts))
	end
	if flags["-b"] then
		key = key:gsub("^%s+", "")
	end
	if flags["-f"] then
		key = key:lower()
	end
	return key
end

-- Version sort: compare digit runs as numbers so Part10 comes after Part9.
local function versionLess(a: string, b: string): boolean
	local ai, bi = 1, 1
	while ai <= #a and bi <= #b do
		local aDigits = a:match("^%d+", ai)
		local bDigits = b:match("^%d+", bi)
		if aDigits and bDigits then
			local an, bn = tonumber(aDigits) :: number, tonumber(bDigits) :: number
			if an ~= bn then
				return an < bn
			end
			ai += #aDigits
			bi += #bDigits
		else
			local ac, bc = a:sub(ai, ai), b:sub(bi, bi)
			if ac ~= bc then
				return ac < bc
			end
			ai += 1
			bi += 1
		end
	end
	return #a - ai < #b - bi
end

HANDLERS.sort = function(self, argv, stdin)
	local flags, values, operands = parse(argv)
	local files, inputErr = inputs(self, expandGlobs(self, operands), stdin)
	if not files then
		return fail("sort", inputErr)
	end
	-- sort concatenates its inputs and sorts the whole thing, which is what
	-- `sort a b` means, not two sorted blocks one after the other.
	local lines: { string } = {}
	for _, file in ipairs(files) do
		for _, line in ipairs(splitLines(file.text)) do
			lines[#lines + 1] = line
		end
	end

	local function less(a: string, b: string): boolean
		local ka, kb = sortKey(a, flags, values), sortKey(b, flags, values)
		if flags["-n"] then
			-- A non-numeric line sorts as 0, which is what sort -n does rather
			-- than erroring.
			local na, nb = tonumber(ka) or 0, tonumber(kb) or 0
			if na ~= nb then
				return na < nb
			end
			return ka < kb
		end
		if flags["-V"] then
			if ka ~= kb then
				return versionLess(ka, kb)
			end
			return false
		end
		return ka < kb
	end

	-- -c only reports whether the input was already sorted; it emits nothing
	-- else and fails when it was not, so `sort -c f && ...` means something.
	if flags["-c"] then
		for index = 2, #lines do
			if less(lines[index], lines[index - 1]) then
				return fail("sort", string.format("line %d is out of order: %s",
					index, lines[index]))
			end
		end
		return ""
	end

	if flags["-R"] then
		-- Fisher-Yates. math.random rather than a sort with a random comparator,
		-- which is not a shuffle and can throw on an inconsistent ordering.
		for i = #lines, 2, -1 do
			local j = math.random(i)
			lines[i], lines[j] = lines[j], lines[i]
		end
	else
		table.sort(lines, function(a, b)
			if flags["-r"] then
				return less(b, a)
			end
			return less(a, b)
		end)
	end

	if flags["-u"] then
		-- Unique by the COMPARISON key, not the whole line, which is what makes
		-- `sort -u -k 2` mean "one line per distinct second field".
		local seen: { [string]: boolean } = {}
		local unique: { string } = {}
		for _, line in ipairs(lines) do
			local key = sortKey(line, flags, values)
			if not seen[key] then
				seen[key] = true
				unique[#unique + 1] = line
			end
		end
		lines = unique
	end

	local result = table.concat(lines, "\n")
	-- -o writes the result to a script instead of returning it, the same way `>`
	-- does: and through self:write, so it carries an undo recording.
	local out = valueOf(values, "-o")
	if out then
		local target, ensureErr = self:ensureScript(out)
		if not target then
			return fail("sort", ensureErr)
		end
		local s, writeErr = self:write(instancePath(target), result .. "\n")
		return s or fail("sort", writeErr)
	end
	return result
end

-- Adjacent-only, as in bash: `sort | uniq` is the idiom, and silently doing a
-- global dedupe would make `uniq -c` counts wrong for anyone who relies on it.
HANDLERS.uniq = function(self, argv, stdin)
	local flags, values, operands = parse(argv)
	local input, inputErr = textInput(self, operands, stdin)
	if not input then return fail("uniq", inputErr) end

	-- What uniq compares, after -f skips fields and -s skips characters and -w
	-- caps the width. The LINE is still what gets printed; only the comparison
	-- narrows, which is the whole point of those three flags.
	local skipFields = numberOf(values, "-f") or 0
	local skipChars = numberOf(values, "-s") or 0
	local width = numberOf(values, "-w")
	local function comparable(line: string): string
		local key = line
		if skipFields > 0 then
			-- Drop the first N whitespace-separated fields, leading blanks and all.
			for _ = 1, skipFields do
				key = key:gsub("^%s*%S+", "", 1)
			end
		end
		if skipChars > 0 then
			key = key:sub(skipChars + 1)
		end
		if width then
			key = key:sub(1, width)
		end
		if flags["-i"] then
			key = key:lower()
		end
		return key
	end

	local out: { string } = {}
	local counts: { number } = {}
	local previous: string? = nil
	for _, line in ipairs(splitLines(input)) do
		local key = comparable(line)
		if previous ~= nil and key == previous then
			counts[#counts] += 1
		else
			out[#out + 1] = line
			counts[#counts + 1] = 1
			previous = key
		end
	end

	-- -d keeps only lines that repeated, -u only lines that did not, -D prints
	-- every member of each repeated run rather than one representative.
	if flags["-d"] or flags["-u"] or flags["-D"] then
		local kept: { string } = {}
		local keptCounts: { number } = {}
		for index, line in ipairs(out) do
			local repeated = counts[index] > 1
			if (repeated and (flags["-d"] or flags["-D"])) or (not repeated and flags["-u"]) then
				local copies = flags["-D"] and counts[index] or 1
				for _ = 1, copies do
					kept[#kept + 1] = line
					keptCounts[#keptCounts + 1] = counts[index]
				end
			end
		end
		out, counts = kept, keptCounts
	end

	if flags["-c"] then
		for index, line in ipairs(out) do
			out[index] = string.format("%4d %s", counts[index], line)
		end
	end
	return table.concat(out, "\n")
end

HANDLERS.mkdir = function(self, argv)
	local flags, _, operands = parse(argv)
	if #operands == 0 then
		return fail("mkdir", "requires a name")
	end
	local out: { string } = {}
	for _, dir in ipairs(operands) do
		if dir ~= "" then
			if flags["-p"] then
				-- Every missing segment, in order, and -p is also mkdir's "already
				-- there is fine", so an existing path is a success, not an error.
				local walked = dir:sub(1, 1) == "/" and "" or self:pwd()
				for segment in dir:gmatch("[^/]+") do
					local parentPath = walked == "" and "/" or walked
					walked = (walked == "" and "" or walked) .. "/" .. segment
					if not self:resolve(walked) then
						local _, err = self:create("Folder", segment, parentPath)
						if err then
							return fail("mkdir", err)
						end
					end
				end
				if flags["-v"] then
					out[#out + 1] = "created " .. walked
				end
			else
				-- mkdir names a path, so split the last segment off.
				local parentPath, leaf = splitPath(dir)
				local s, err = self:create("Folder", leaf, parentPath)
				if not s then
					return fail("mkdir", err)
				end
				out[#out + 1] = s
			end
		end
	end
	return table.concat(out, "\n")
end

HANDLERS.touch = function(self, argv)
	local flags, values, operands = parse(argv)
	if #operands == 0 then
		return fail("touch", "requires a name")
	end

	-- -d/-t/-r set the observed modification time rather than "now", which is
	-- the whole of what touch's time flags can mean here: there is no stored
	-- timestamp to change, only the journal this plugin keeps.
	local when: number? = nil
	local reference = valueOf(values, "-r")
	if reference then
		local other, err = self:resolve(reference)
		if not other then
			return fail("touch", err)
		end
		when = Fs.mtime(other)
		if not when then
			return fail("touch", string.format(
				"-r %s: no observed modification time for it to copy", reference))
		end
	end
	local stamp = valueOf(values, "-d") or valueOf(values, "-t")
	if stamp then
		-- A bare epoch second, or @seconds. Calendar strings are refused rather
		-- than half-parsed: "next tuesday" silently becoming `now` is the kind of
		-- wrong answer that only shows up much later.
		local seconds = tonumber((stamp:gsub("^@", "")))
		if not seconds then
			return fail("touch", string.format("-d %q: give a time as epoch seconds " ..
				"(or @seconds) — there is no date parser here, and guessing at a " ..
				"calendar string would set a time nobody asked for", stamp))
		end
		when = seconds
	end

	local out: { string } = {}
	for _, target in ipairs(operands) do
		if target ~= "" then
			local existing = self:resolve(target)
			if existing then
				Fs.touch(existing, when)
				if flags["-v"] then
					out[#out + 1] = "touched " .. instancePath(existing)
				end
			elseif flags["-c"] then
				-- -c: do not create what is missing. Silence is the whole point.
			else
				local parentPath, leaf = splitPath(target)
				local class, name = classFor(leaf)
				local s, err = self:create(class, name, parentPath)
				if not s then
					return fail("touch", err)
				end
				local created = self:resolve(target)
				if created and when then
					Fs.touch(created, when)
				end
				out[#out + 1] = s
			end
		end
	end
	return table.concat(out, "\n")
end

HANDLERS.rm = function(self, argv)
	local flags, _, operands = parse(argv)
	if #operands == 0 then
		-- -f makes a missing operand a no-op, exactly as it does a missing file.
		return flags["-f"] and "" or fail("rm", "requires a path")
	end
	-- Every operand, not just the first: `rm a b c` used to destroy a and say
	-- nothing at all about b and c.
	local out: { string } = {}
	for _, path in ipairs(expandGlobs(self, operands)) do
		-- Real rm refuses a directory without -r, and that refusal is the whole
		-- reason a mistyped path costs a turn instead of a subtree. This used to
		-- recurse silently, so `rm /Workspace/Model` took 500 descendants with it
		-- and reported success.
		--
		-- A script is a file here and needs no flag; everything else is a
		-- directory: the same split `-type f` / `-type d` already uses.
		local doomed = self:resolve(path)
		if doomed and not isScript(doomed) and not (flags["-r"] or flags["-R"]) then
			local children = #doomed:GetChildren()
			-- -d removes an empty container, which is the one case that needs no -r.
			if not (flags["-d"] and children == 0) then
				return fail("rm", string.format(
					"%s is a container%s — use -r to remove it and everything inside",
					instancePath(doomed),
					children > 0 and string.format(" with %d children", children) or " (empty; -d also works)"))
			end
		end
		local s, err = self:remove(path)
		if not s then
			-- -f makes a missing path a no-op rather than a failure, which is what
			-- lets `rm -f x` be safe to run whether or not x is there.
			if not flags["-f"] then
				return fail("rm", err)
			end
		else
			out[#out + 1] = s
		end
	end
	return table.concat(out, "\n")
end

-- mv and cp differ only in whether the original survives, so they share their
-- argument handling, which is where the interesting part is.
--
-- bash operand semantics: the LAST operand is the destination and everything
-- before it is a source. This used to read `mv a b c` as "move a into b, rename
-- to c", a third operand real mv does not have, which made the ordinary
-- `mv a b Folder/` impossible to express.
local function moveOrCopy(self: any, cmd: string, argv: { string }): string
	local flags, values, operands = parse(argv)
	local destination = valueOf(values, "-t")
	local sources = operands
	if not destination then
		if #operands < 2 then
			return fail(cmd, "requires a source path and a destination path")
		end
		destination = operands[#operands]
		sources = table.move(operands, 1, #operands - 1, 1, {})
	end
	sources = expandGlobs(self, sources)

	-- With more than one source the destination has to be an existing container;
	-- otherwise the last one silently wins the name and the rest are lost.
	if #sources > 1 and not self:resolve(destination) then
		return fail(cmd, string.format(
			"target %q is not an existing container, and %d sources need one",
			destination, #sources))
	end

	-- -T refuses to treat the destination as a directory, so `mv a b` renames
	-- even when b already exists as a container.
	local name: string? = nil
	local parent = destination
	if flags["-T"] then
		local parentPath, leaf = splitPath(destination :: string)
		parent, name = parentPath or ".", leaf
	end

	local out: { string } = {}
	for _, source in ipairs(sources) do
		-- -n declines to overwrite. Checked against the resolved container so it
		-- means the same thing whether the destination is a folder or a new name.
		if flags["-n"] then
			local existing = self:resolve(destination)
			local leaf = select(2, splitPath(source))
			if existing and existing:FindFirstChild(Fs.stripScriptSuffix(leaf) or leaf) then
				continue
			end
		end
		-- Written out rather than as `cmd == "mv" and move(...) or copy(...)`,
		-- which was wrong twice over: `a and b or c` yields ONE value, so `err`
		-- was always nil and every failure reported as "cp: nil", and when a
		-- move FAILED it returned nil, so the `or` fell through and performed a
		-- COPY instead. A refused move silently left a duplicate behind.
		local s, err
		if cmd == "mv" then
			s, err = self:move(source, parent, name)
		else
			s, err = self:copy(source, parent, name)
		end
		if not s then
			if flags["-f"] then
				continue
			end
			return fail(cmd, err)
		end
		out[#out + 1] = s
	end
	return table.concat(out, "\n")
end

HANDLERS.mv = function(self, argv)
	return moveOrCopy(self, "mv", argv)
end

HANDLERS.cp = function(self, argv)
	return moveOrCopy(self, "cp", argv)
end

-- chmod, over the three bits that exist. It was in UNSUPPORTED because "no
-- permission bits" was the obvious answer and the wrong one: Disabled,
-- Archivable and Locked mean exactly what x, a and l mean, and `ls -l` prints
-- them, so having no way to change them was the actual gap.
HANDLERS.chmod = function(self, argv)
	local flags, _, operands = parse(argv)
	local mode = operands[1]
	if not mode or #operands < 2 then
		return fail("chmod", "requires a mode and a path, as `chmod +x Main.luau`")
	end
	local sign, letters = mode:match("^([%+%-=])(%a*)$")
	if not sign then
		if mode:match("^%d+$") then
			return fail("chmod", "octal modes encode user/group/other, and there is no " ..
				"owner here to give those three digits a meaning. Use +x (runs), " ..
				"+a (Archivable) or +l (Locked).")
		end
		return fail("chmod", string.format("%q is not a mode — write +x, -x, +a, -a, " ..
			"+l or -l (x runs, a Archivable, l Locked)", mode))
	end

	local out: { string } = {}
	local function apply(inst: Instance): string?
		for letter in letters:gmatch(".") do
			local err = Fs.setMode(inst, letter, sign ~= "-")
			if err then
				return err
			end
		end
		if flags["-v"] then
			out[#out + 1] = string.format("%s %s", Fs.modeString(inst), instancePath(inst))
		end
		return nil
	end

	for index = 2, #operands do
		local target, err = self:resolve(operands[index])
		if not target then
			return flags["-f"] and "" or fail("chmod", err)
		end
		local targets = { target }
		if flags["-R"] then
			local descendants = target:GetDescendants()
			table.move(descendants, 1, #descendants, 2, targets)
		end
		local _, applyErr = withUndo("Claude: chmod " .. mode, function()
			for _, inst in ipairs(targets) do
				local modeErr = apply(inst)
				-- Under -R most instances have no execute bit and that is not an
				-- error, it is the tree being mixed. A single explicit target that
				-- cannot take the bit still has to say so.
				if modeErr and not flags["-R"] and not flags["-f"] then
					error(modeErr, 0)
				end
			end
		end)
		if applyErr then
			return fail("chmod", applyErr)
		end
	end
	if #out == 0 then
		local target = self:resolve(operands[2])
		return target and string.format("%s %s", Fs.modeString(target), instancePath(target)) or ""
	end
	return table.concat(out, "\n")
end

HANDLERS.ln = function(self, argv)
	-- An ObjectValue is the DataModel's reference-to-another-instance, which is
	-- as close as this tree gets to a symlink. It does not behave like one for
	-- cd or cat, nothing resolves through it, so the result says so.
	local flags, _, operands = parse(argv)
	if not flags["-s"] then
		-- A hard link is a second directory entry for one inode. An Instance has
		-- exactly one Parent, so there is no second entry to make, and quietly
		-- producing an ObjectValue instead would answer a question nobody asked.
		return fail("ln", "a hard link needs a second name for one object, and an " ..
			"Instance has exactly one Parent. `ln -s` makes an ObjectValue pointing " ..
			"at it, which is the nearest thing here.")
	end
	local target, err = self:resolve(operands[1])
	if not target then
		return fail("ln", err)
	end
	local dir = operands[2]
	if not dir or dir == "" then
		return "ln: requires a link name"
	end
	local parentPath, leaf = splitPath(dir)
	local parent, parentErr = self:resolve(parentPath)
	if not parent then
		return fail("ln", parentErr)
	end
	-- -f replaces an existing link rather than colliding with it.
	local clash = parent:FindFirstChild(leaf)
	if clash then
		if not flags["-f"] then
			return fail("ln", string.format("%s already exists — pass -f to replace it",
				instancePath(clash)))
		end
		local _, removeErr = self:remove(instancePath(clash))
		if removeErr then
			return fail("ln", removeErr)
		end
	end

	local link, linkErr = withUndo("Claude: ln " .. leaf, function()
		local value = Instance.new("ObjectValue")
		value.Name = leaf
		value.Value = target
		value.Parent = parent
		return value
	end)
	if linkErr then
		return fail("ln", linkErr)
	end
	return string.format("%s -> %s (ObjectValue; nothing resolves through it)",
		instancePath(link :: Instance), instancePath(target))
end

HANDLERS.sed = function(self, argv, stdin)
	local flags, values, operands = parse(argv)

	-- -e names an expression explicitly and repeats; without it the first
	-- operand is the expression and the rest are files.
	local expressions: { string } = values["-e"] or {}
	local firstFile = 1
	if #expressions == 0 then
		if not operands[1] then
			return fail("sed", "requires an expression, e.g. s/old/new/ or -n '10,40p'")
		end
		expressions = { operands[1] }
		firstFile = 2
	end

	local extended = flags["-E"] or flags["-r"] or false
	local commands: { SedCommand } = {}
	for _, expr in ipairs(expressions) do
		-- One -e can still carry several commands separated by newlines or `;`,
		-- which is how `sed '1d;$d'` is written.
		for piece in (expr .. "\n"):gmatch("([^\n;]*)[\n;]") do
			if piece:match("%S") then
				local command, parseErr = parseSedCommand(piece, extended)
				if not command then
					return fail("sed", parseErr)
				end
				commands[#commands + 1] = command
			end
		end
	end
	if #commands == 0 then
		return fail("sed", "requires an expression, e.g. s/old/new/ or -n '10,40p'")
	end

	local files: { string } = {}
	for index = firstFile, #operands do
		files[#files + 1] = operands[index]
	end
	local path = files[1]

	local input, inputErr = textInput(self, { path }, stdin)
	if not input then
		return fail("sed", inputErr)
	end
	if flags["-i"] and not path then
		return fail("sed", "-i edits a file in place, so it needs a file operand")
	end
	-- Real sed would happily truncate a file to a printed range. That is a
	-- destructive reading of a flag combination whose whole purpose is to read,
	-- so it is refused rather than performed.
	if flags["-i"] and flags["-n"] then
		return fail("sed", "-i -n would overwrite the file with only the printed lines; " ..
			"drop one of them")
	end

	local lines = splitLines(input)
	local out: { string } = {}
	local active: { [number]: boolean } = {}
	local quiet = flags["-n"] == true

	for index, line in ipairs(lines) do
		local text = line
		local deleted = false
		local before: { string } = {}
		local after: { string } = {}
		local quit = false

		for slot, command in ipairs(commands) do
			if not sedSelects(command, index, text, #lines, active, slot) then
				continue
			end
			local name = command.name
			if name == "s" then
				local args = command.args
				-- The pattern compiled at parse time, so a bad one was refused
				-- before any line ran. What is left to go wrong is the step
				-- budget, which aborts the whole substitution rather than leaving
				-- the file half-rewritten.
				local ok, res, changed = pcall(substitute, args.program, text,
					args.replacement, args.global, args.occurrence)
				if not ok then
					return fail("sed", Regex.isBudget(res)
						and "that pattern is too expensive to run — anchor it, or replace a " ..
							"nested quantifier like (a+)+ with a single one"
						or tostring(res))
				end
				text = res
				-- `p` prints the line only when the substitution actually fired.
				-- With -n that is the whole output, which is what makes
				-- `sed -n 's/x/y/p'` mean "show me just the changed lines".
				if args.print and (changed :: number) > 0 then
					after[#after + 1] = text
				end
			elseif name == "y" then
				local args = command.args
				local from = expandTrSet(args.pattern)
				local to = expandTrSet(args.replacement)
				if #from ~= #to then
					return fail("sed", "y/// needs both sets to be the same length")
				end
				text = text:gsub(".", function(c)
					local at = from:find(c, 1, true)
					return at and to:sub(at, at) or c
				end)
			elseif name == "d" then
				deleted = true
				break
			elseif name == "p" then
				-- Without -n every line prints anyway, so an explicit p doubles it
				-- which is exactly what `sed p` does.
				after[#after + 1] = text
			elseif name == "=" then
				before[#before + 1] = tostring(index)
			elseif name == "a" then
				after[#after + 1] = command.args
			elseif name == "i" then
				before[#before + 1] = command.args
			elseif name == "c" then
				text = command.args
			elseif name == "q" then
				quit = true
				break
			end
		end

		for _, extra in ipairs(before) do
			out[#out + 1] = extra
		end
		if not deleted and not quiet then
			out[#out + 1] = text
		end
		for _, extra in ipairs(after) do
			out[#out + 1] = extra
		end
		if quit then
			break
		end
	end

	local result = table.concat(out, "\n")

	-- `sed -i` writes back, which is the whole point of the flag. It goes
	-- through :write, so the substitution lands in one undo record like every
	-- other mutation rather than being the one edit Ctrl+Z cannot reach.
	if flags["-i"] then
		local s, writeErr = self:write(path, result .. "\n")
		return s or fail("sed", writeErr)
	end
	return result
end

-- diff
-- A real longest-common-subsequence diff. This used to walk both files by index
-- and call every position where they disagreed a change, so inserting ONE line
-- at the top of a 400-line module reported all 400 as different, a result that
-- is not merely noisy but wrong about which lines changed. None of -u, -b or -w
-- can be built honestly on top of that, because none of them mean anything
-- until the aligner knows which lines correspond to which.
--
-- ponytail: classic O(n*m) dynamic-programming table over the differing middle
-- only. The common prefix and suffix are trimmed first, so the quadratic part
-- sees the edit rather than the file, which is what keeps it cheap for the case
-- that actually happens. Ceiling: MAX_DIFF_LINES of genuinely differing text,
-- past which it reports the size instead of allocating; Myers' algorithm is the
-- upgrade path if that is ever hit in practice.
local MAX_DIFF_LINES = 1200

-- What counts as "the same line". -w ignores whitespace entirely, -b collapses
-- runs of it, -i folds case. Comparison only, the ORIGINAL line is what gets
-- printed, so a whitespace-only change is invisible under -w rather than
-- silently rewritten.
local function diffKey(line: string, flags: { [string]: boolean }): string
	local key = line
	if flags["-w"] then
		key = key:gsub("%s", "")
	elseif flags["-b"] then
		key = key:gsub("%s+", " "):gsub("^ +", ""):gsub(" +$", "")
	end
	if flags["-i"] then
		key = key:lower()
	end
	return key
end

type DiffOp = { op: string, a: number?, b: number? }

local function diffLines(a: { string }, b: { string },
	key: (string) -> string): ({ DiffOp }?, string?)
	local script: { DiffOp } = {}

	-- Trim the common prefix, then the common suffix. For the usual shape of an
	-- edit: a few lines changed in a large file, this leaves almost nothing
	-- for the quadratic part below.
	local head = 0
	while head < #a and head < #b and key(a[head + 1]) == key(b[head + 1]) do
		head += 1
		script[#script + 1] = { op = " ", a = head, b = head }
	end
	local tail = 0
	while #a - tail > head and #b - tail > head
		and key(a[#a - tail]) == key(b[#b - tail]) do
		tail += 1
	end

	local n, m = #a - tail - head, #b - tail - head
	if n * m > MAX_DIFF_LINES * MAX_DIFF_LINES then
		return nil, string.format("%d and %d lines differ — too much to align. " ..
			"Diff a narrower range, or grep for what changed.", n, m)
	end

	-- lengths[i][j] is the LCS length of a[i..n] against b[j..m], built from the
	-- far end so the backtrack below can walk forwards and emit in file order.
	local lengths: { { number } } = {}
	for i = n + 1, 1, -1 do
		local row: { number } = {}
		lengths[i] = row
		for j = m + 1, 1, -1 do
			if i > n or j > m then
				row[j] = 0
			elseif key(a[head + i]) == key(b[head + j]) then
				row[j] = lengths[i + 1][j + 1] + 1
			else
				row[j] = math.max(lengths[i + 1][j], row[j + 1])
			end
		end
	end

	local i, j = 1, 1
	while i <= n and j <= m do
		if key(a[head + i]) == key(b[head + j]) then
			script[#script + 1] = { op = " ", a = head + i, b = head + j }
			i += 1
			j += 1
		elseif lengths[i + 1][j] >= lengths[i][j + 1] then
			script[#script + 1] = { op = "-", a = head + i }
			i += 1
		else
			script[#script + 1] = { op = "+", b = head + j }
			j += 1
		end
	end
	while i <= n do
		script[#script + 1] = { op = "-", a = head + i }
		i += 1
	end
	while j <= m do
		script[#script + 1] = { op = "+", b = head + j }
		j += 1
	end
	for k = 1, tail do
		script[#script + 1] = { op = " ", a = #a - tail + k, b = #b - tail + k }
	end
	return script, nil
end

-- Unified format: only the changed regions, each with `context` lines around it,
-- under an @@ header naming where it sits in both files. The default output,
-- because it is the one that says WHERE a change is without reprinting the file.
local function unified(script: { DiffOp }, a: { string }, b: { string },
	pathA: string, pathB: string, context: number): string
	-- Group changes that are close enough that their context windows touch.
	local hunks: { { first: number, last: number } } = {}
	for index, op in ipairs(script) do
		if op.op ~= " " then
			local last = hunks[#hunks]
			if last and index - last.last <= context * 2 + 1 then
				last.last = index
			else
				hunks[#hunks + 1] = { first = index, last = index }
			end
		end
	end
	if #hunks == 0 then
		return ""
	end

	local out: { string } = { "--- " .. pathA, "+++ " .. pathB }
	for _, hunk in ipairs(hunks) do
		local from = math.max(1, hunk.first - context)
		local to = math.min(#script, hunk.last + context)
		local startA, startB, countA, countB = nil, nil, 0, 0
		local body: { string } = {}
		for index = from, to do
			local op = script[index]
			if op.a then
				startA = startA or op.a
				if op.op ~= "+" then
					countA += 1
				end
			end
			if op.b then
				startB = startB or op.b
				if op.op ~= "-" then
					countB += 1
				end
			end
			body[#body + 1] = op.op .. (op.op == "+" and b[op.b :: number] or a[op.a :: number])
		end
		out[#out + 1] = string.format("@@ -%d,%d +%d,%d @@",
			startA or 0, countA, startB or 0, countB)
		table.move(body, 1, #body, #out + 1, out)
	end
	return table.concat(out, "\n")
end

-- Compare one pair of scripts. Split out so -r can call it per child.
local function diffOne(self: any, a: Instance, b: Instance,
	flags: { [string]: boolean }, values: { [string]: { string } }): string
	local pathA, pathB = instancePath(a), instancePath(b)
	local srcA, srcB = getSource(a), getSource(b)
	if not srcA or not srcB then
		local which = not srcA and pathA or pathB
		return fail("diff", "not a script: " .. which)
	end

	local linesA, linesB = splitLines(srcA), splitLines(srcB)
	local script, err = diffLines(linesA, linesB, function(line)
		return diffKey(line, flags)
	end)
	if not script then
		return fail("diff", err)
	end

	local changed = false
	for _, op in ipairs(script) do
		if op.op ~= " " then
			changed = true
			break
		end
	end
	-- -B ignores changes that are only blank lines, checked after alignment
	-- because "only blank lines" is a property of the edit, not of the files.
	if changed and flags["-B"] then
		changed = false
		for _, op in ipairs(script) do
			local text = op.op == "+" and linesB[op.b :: number] or linesA[op.a :: number]
			if op.op ~= " " and text:match("%S") then
				changed = true
				break
			end
		end
	end

	if not changed then
		-- -s says so out loud; without it identical files are silence, which is
		-- what makes `diff a b && echo same` work.
		return flags["-s"] and string.format("%s and %s are identical", pathA, pathB) or ""
	end
	if flags["-q"] then
		return string.format("%s and %s differ", pathA, pathB)
	end

	if flags["-y"] then
		local out: { string } = {}
		for _, op in ipairs(script) do
			local left = op.a and linesA[op.a] or ""
			local right = op.b and linesB[op.b] or ""
			local marker = op.op == " " and " " or (op.op == "-" and "<" or ">")
			out[#out + 1] = string.format("%-40s %s %s", left:sub(1, 40), marker, right)
		end
		return table.concat(out, "\n")
	end

	return unified(script, linesA, linesB, pathA, pathB, numberOf(values, "-U") or 3)
end

HANDLERS.diff = function(self, argv)
	local flags, values, operands = parse(argv)
	if not operands[1] or not operands[2] then
		return fail("diff", "requires two paths to compare")
	end
	local a, errA = self:resolve(operands[1])
	if not a then return fail("diff", errA) end
	local b, errB = self:resolve(operands[2])
	if not b then return fail("diff", errB) end

	if not flags["-r"] then
		return diffOne(self, a, b, flags, values)
	end

	-- -r walks two containers together, pairing children by name. A name present
	-- on one side only is reported as such rather than skipped: "only in" is
	-- most of what a recursive diff is asked for.
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, childA in ipairs(a:GetChildren()) do
		seen[childA.Name] = true
		local childB = b:FindFirstChild(childA.Name)
		if not childB then
			out[#out + 1] = string.format("Only in %s: %s", instancePath(a), childA.Name)
		elseif getSource(childA) and getSource(childB) then
			local text = diffOne(self, childA, childB, flags, values)
			if text ~= "" then
				out[#out + 1] = text
			end
		end
	end
	for _, childB in ipairs(b:GetChildren()) do
		if not seen[childB.Name] then
			out[#out + 1] = string.format("Only in %s: %s", instancePath(b), childB.Name)
		end
	end
	return table.concat(out, "\n")
end

HANDLERS.tr = function(self, argv, stdin)
	local flags, _, operands = parse(argv)
	local set1 = expandTrSet(operands[1] or "")
	-- -d and -s take one set; only a translation needs two. Requiring two
	-- unconditionally is why `tr -d '\n'` failed even once the escape was
	-- understood.
	local oneSet = flags["-d"] or flags["-s"]
	local set2 = expandTrSet(operands[2] or "")
	if set1 == "" or (set2 == "" and not oneSet) then
		return fail("tr", "requires two character sets, e.g. `tr a-z A-Z` — " ..
			"or one with -d or -s, as `tr -d '\\n'`")
	end

	-- -c complements set1: act on every byte NOT in it.
	if flags["-c"] or flags["-C"] then
		local inSet: { [string]: boolean } = {}
		for index = 1, #set1 do
			inSet[set1:sub(index, index)] = true
		end
		local complement = {}
		for code = 0, 255 do
			local char = string.char(code)
			if not inSet[char] then
				complement[#complement + 1] = char
			end
		end
		set1 = table.concat(complement)
	end

	-- Both sets are operands, so a file (if any) is the third, or the second
	-- when only one set was given.
	local input, inputErr = textInput(self, { operands[oneSet and 2 or 3] }, stdin)
	if not input then
		return fail("tr", inputErr)
	end

	-- -t truncates set1 to set2's length instead of padding. Without it tr pads
	-- set2 with its last character, which is what makes `tr a-z x` work.
	if flags["-t"] then
		set1 = set1:sub(1, #set2)
	end

	-- The WHOLE input, not line by line. tr is a byte filter, and splitting into
	-- lines first makes "\n" unreachable: `tr -d '\n'` would strip the newlines
	-- out of each line (there are none) and then the join would put them back,
	-- so the command reported success and changed nothing.
	local mapped: { string } = {}
	local lastKept: string? = nil
	for index = 1, #input do
		local c = input:sub(index, index)
		local pos = set1:find(c, 1, true)
		if flags["-d"] and pos then
			lastKept = nil
			continue
		end
		local replacement = c
		if pos and #set2 > 0 and not flags["-d"] then
			-- Past the end of set2, tr repeats its last character.
			replacement = set2:sub(math.min(pos, #set2), math.min(pos, #set2))
		end
		-- -s squeezes a run of characters that are IN the set down to one, after
		-- any translation.
		if flags["-s"] and replacement == lastKept
			and (set2 ~= "" and set2 or set1):find(replacement, 1, true) then
			continue
		end
		mapped[#mapped + 1] = replacement
		lastKept = replacement
	end
	return table.concat(mapped)
end

HANDLERS.basename = function(_, argv)
	local flags, values, operands = parse(argv)
	if not operands[1] then return "" end
	-- Two shapes: `basename PATH [SUFFIX]` strips a suffix from one path, and
	-- `basename -a PATH...` names every operand. -s makes the suffix explicit so
	-- both can be had at once.
	local suffix = valueOf(values, "-s")
	local paths = operands
	if not suffix and not flags["-a"] and operands[2] then
		suffix = operands[2]
		paths = { operands[1] }
	end
	local out: { string } = {}
	for _, path in ipairs(paths) do
		local parts = path:split("/")
		local leaf = parts[#parts] or ""
		if suffix and suffix ~= "" and #leaf > #suffix and leaf:sub(-#suffix) == suffix then
			leaf = leaf:sub(1, -#suffix - 1)
		end
		out[#out + 1] = leaf
	end
	return table.concat(out, "\n")
end

HANDLERS.dirname = function(_, argv)
	local _, _, operands = parse(argv)
	if not operands[1] then return "" end
	local out: { string } = {}
	for _, path in ipairs(operands) do
		local parent = path:match("^(.*)/[^/]+$")
		out[#out + 1] = (parent == "" and "/") or parent or "."
	end
	return table.concat(out, "\n")
end

-- file answers ONE question, what kind of thing is this, in one line, the way
-- file(1) does. It shared stat's handler until that turned every `file x` into
-- a full metadata block whose second line held the actual answer.
--
-- The class IS the answer here: there is no magic number to sniff, and an
-- instance's type is a property rather than something inferred from content.
-- Scripts get the extra word because that is the distinction the caller is
-- usually making, and it is the one `ls` already draws with its .luau suffix.
HANDLERS.file = function(self, argv)
	local flags, _, operands = parse(argv)
	if #operands == 0 then
		return fail("file", "requires a path")
	end
	local out: { string } = {}
	for _, path in ipairs(expandGlobs(self, operands)) do
		local target, err = self:resolve(path)
		if not target then
			return fail("file", err)
		end
		local kind = target.ClassName
		if isScript(target) then
			kind ..= " (script)"
		elseif #target:GetChildren() > 0 then
			kind ..= string.format(" (%d children)", #target:GetChildren())
		end
		out[#out + 1] = flags["-b"] and kind
			or string.format("%s: %s", instancePath(target), kind)
	end
	return table.concat(out, "\n")
end
-- rmdir removes an EMPTY container, and refusing a full one is its entire
-- purpose. It shared rm's handler, which quietly made it `rm -r`, the same
-- alias-sharing defect as egrep sharing grep's function, except this one
-- deletes. Given its own handler for exactly that reason.
HANDLERS.rmdir = function(self, argv)
	local flags, _, operands = parse(argv)
	if #operands == 0 then
		return fail("rmdir", "requires a path")
	end
	local out: { string } = {}
	for _, path in ipairs(expandGlobs(self, operands)) do
		local target, err = self:resolve(path)
		if not target then
			return fail("rmdir", err)
		end
		if isScript(target) then
			return fail("rmdir", string.format("%s is a script, not a container — use rm",
				instancePath(target)))
		end
		local children = #target:GetChildren()
		if children > 0 then
			return fail("rmdir", string.format(
				"%s is not empty (%d children) — rmdir only removes empty containers, " ..
					"`rm -r` removes one and everything inside",
				instancePath(target), children))
		end
		-- -p walks up removing each parent that the removal just emptied. The
		-- service guard in Fs stops the climb at the top on its own.
		local climbing = target.Parent
		local s, removeErr = self:remove(instancePath(target))
		if not s then
			return fail("rmdir", removeErr)
		end
		out[#out + 1] = s
		while flags["-p"] and climbing and #climbing:GetChildren() == 0 do
			local parent = climbing.Parent
			local up, upErr = self:remove(instancePath(climbing))
			if not up then
				-- Hitting a service is where the climb is SUPPOSED to stop, so it
				-- ends the loop rather than failing the command.
				if upErr then break end
			else
				out[#out + 1] = up
			end
			climbing = parent
		end
	end
	return table.concat(out, "\n")
end
HANDLERS.egrep = HANDLERS.grep
HANDLERS.fgrep = HANDLERS.grep

local COMMANDS: { string } = {}
for name in pairs(HANDLERS) do
	COMMANDS[#COMMANDS + 1] = name
end
table.sort(COMMANDS)
-- Exported so /help can print the real command set instead of a hand-written
-- copy that goes stale the moment a handler is added.
Shell.COMMANDS = COMMANDS

-- Shell metacharacters that survive tokenizing as their own token. Folding them
-- into an argument silently is worse than saying they don't work. A QUOTED one
-- is exempt: `grep "<" f` is a pattern, not a redirection, which is what the
-- quoted-position set from tokenize() is for.
local METACHARACTERS: { [string]: boolean } = {
	["<"] = true, ["&"] = true,
}


-- Commands `/sh` is allowed to run. An allowlist rather than "anything not in a
-- MUTATES list": a command added later should be unavailable to the user-facing
-- shell until someone decides it is safe, rather than exposed by default. The
-- check is per command, not per line, so `;` cannot smuggle an rm past it.
local READ_ONLY: { [string]: boolean } = {
	cat = true, cd = true, diff = true, du = true, echo = true, file = true,
	find = true, grep = true, egrep = true, fgrep = true, head = true, ls = true,
	pwd = true, sed = true, stat = true, tail = true, tr = true, tree = true,
	wc = true, which = true, basename = true, dirname = true, whoami = true,
}

-- The one flag that turns each read-only command into a mutating one. Kept as a
-- table so adding a destructive option to an allowlisted command is a visible
-- decision rather than something that lands by omission.
local MUTATING_FLAGS: { [string]: { flag: string, why: string } } = {
	sed  = { flag = "-i",      why = "sed -i writes to the script" },
	sort = { flag = "-o",      why = "sort -o writes its result to a script" },
	find = { flag = "-delete", why = "find -delete destroys instances" },
}

-- Commands that can consume a stream. Anything else in a pipeline is a mistake
-- worth naming: `ls | ls` silently ignoring its input is how a wrong answer
-- looks exactly like a right one.
local STDIN_COMMANDS: { [string]: boolean } = {
	cat = true, grep = true, egrep = true, fgrep = true,
	head = true, tail = true, wc = true, sort = true, uniq = true,
	sed = true, tr = true,
}

-- One command, already tokenized. `stdin` is a heredoc body or the previous
-- stage's output; `> path` sends this command's output to a script instead.
local function runCommand(self: any, argv: { string }, readOnly: boolean?, stdin: string?): (string, boolean)
	failed = false
	local args, redirect, append = takeRedirect(argv)
	if redirect and readOnly then
		return fail("bash", "redirection is not available here — /sh is read-only"), false
	end
	if #args == 0 then
		if redirect and redirect ~= DEV_NULL then
			return applyRedirect(self, redirect, stdin or "", append), not failed
		end
		return "", true
	end

	local cmd = args[1]
	if readOnly and not READ_ONLY[cmd] then
		return fail("bash", cmd .. " is not available here — /sh is read-only"), false
	end
	-- READ_ONLY is an allowlist of COMMANDS, and `sed` and `find` earned their
	-- places there by only ever reading. One flag turns each into a mutating one,
	-- so that flag has to be named explicitly, otherwise a single new option
	-- quietly punches a hole in /sh, which exists so that every mutation arrives
	-- through Claude with an undo recording attached.
	local mutator = readOnly and MUTATING_FLAGS[cmd]
	if mutator then
		for _, arg in ipairs(args) do
			-- Prefix, not equality: the flag can arrive bundled (`sed -in`) or with
			-- its value glued on (`sort -oout.luau`), and this check must fail
			-- CLOSED: refusing a read-only command that was not going to write is
			-- a corrected turn, letting a write through is a hole in /sh.
			--
			-- Matched against the raw argument rather than the parsed flag set
			-- because `find` has no spec: its -delete never becomes a flag, it is
			-- parsed by the handler itself.
			if arg:sub(1, #mutator.flag) == mutator.flag then
				return fail("bash", mutator.why .. " — /sh is read-only"), false
			end
		end
	end
	if stdin and not STDIN_COMMANDS[cmd] then
		return fail("bash", cmd .. " does not read input — pipe into cat, grep, head, tail, wc, sort, uniq, sed or tr"), false
	end
	-- Before the handler, so an unknown flag fails on its own terms instead of
	-- surviving as an ignored flag and a stray positional argument.
	local _, _, _, flagErr = partition(args, SPECS[cmd])
	if flagErr then
		return fail(cmd, flagErr), false
	end

	local handler = HANDLERS[cmd]
	local output
	if handler then
		output = handler(self, args, stdin)
	elseif isSeparateTool(cmd) then
		return fail("bash", cmd .. " is a separate tool, not a shell command"), false
	else
		local why = UNSUPPORTED[cmd]
		if why then
			return fail("bash", cmd .. ": " .. why), false
		end
		return fail("bash", string.format("unknown command %q — available: %s",
			cmd, table.concat(COMMANDS, " "))), false
	end

	local ok = not failed
	if redirect == DEV_NULL then
		return "", ok        -- ran it, threw the output away
	end
	if redirect then
		return applyRedirect(self, redirect, output, append), not failed
	end
	return output, ok
end

-- A pipeline: each stage's output becomes the next stage's input. A failing
-- stage stops the pipeline rather than feeding an error message downstream as
-- if it were data.
local function runPipeline(self: any, stages: { { string } }, readOnly: boolean?, stdin: string?): (string, boolean)
	local input = stdin
	local output, ok = "", true
	for _, stage in ipairs(stages) do
		output, ok = runCommand(self, stage, readOnly, input)
		if not ok then
			return output, false
		end
		input = output
	end
	return output, ok
end

-- Split tokenized argv into statements joined by `;`, `&&` or `||`, each of
-- which is a list of pipeline stages split on `|`.
local SEPARATORS: { [string]: boolean } = { [";"] = true, ["&&"] = true, ["||"] = true }

type Statement = { joiner: string, stages: { { string } } }

local function parseStatements(argv: { string }): { Statement }
	local statements: { Statement } = {}
	local current: Statement = { joiner = ";", stages = { {} } }

	local function flush()
		local stages: { { string } } = {}
		for _, stage in ipairs(current.stages) do
			if #stage > 0 then
				stages[#stages + 1] = stage
			end
		end
		if #stages > 0 then
			current.stages = stages
			statements[#statements + 1] = current
		end
	end

	for _, arg in ipairs(argv) do
		if SEPARATORS[arg] then
			flush()
			current = { joiner = arg, stages = { {} } }
		elseif arg == "|" then
			current.stages[#current.stages + 1] = {}
		else
			local stage = current.stages[#current.stages]
			stage[#stage + 1] = arg
		end
	end
	flush()
	return statements
end

local function label(statement: Statement): string
	local parts: { string } = {}
	for _, stage in ipairs(statement.stages) do
		parts[#parts + 1] = table.concat(stage, " ")
	end
	return table.concat(parts, " | ")
end

-- Run a `bash` line. Split out from dispatch so the tokenizer and the command
-- table can be tested without going through tool_use plumbing.
--
-- `readOnly` is for /sh, where the human types the line directly and mutations
-- should stay Claude's, every write it makes carries an undo recording.
function Shell.run(self: any, line: string?, readOnly: boolean?): string
	local commandLine, stdin, heredocErr = extractHeredoc(line or "")
	if heredocErr then
		return "bash: " .. heredocErr
	end

	-- There is no stderr here, errors come back as ordinary output, so the
	-- redirections that aim at it are noise rather than instructions, and the
	-- right thing to do with noise is drop it. Without this, `2>&1` was not
	-- merely inert: the tokenizer splits `&` into its own token, which the
	-- metacharacter check then rejected as an attempt to background a command.
	-- A trailing `2>&1` is one of the most reflexive things there is to type,
	-- and it failed the whole line.
	--
	-- Runs after the heredoc has been lifted out, so a body containing `2>&1`
	-- as ordinary source text is never touched.
	commandLine = commandLine
		:gsub("&>>", ">>")          -- both streams appended -> there is one stream
		:gsub("&>", ">")
		:gsub("%d?>&%-", " ")       -- 2>&-  close stderr
		:gsub("%d?>&%d", " ")       -- 2>&1, 1>&2, >&2

	local argv, tokenErr, quoted = tokenize(commandLine)
	if not argv then
		return "bash: " .. tostring(tokenErr)
	end
	for index, arg in ipairs(argv) do
		if METACHARACTERS[arg] and not quoted[index] then
			return string.format("bash: %s is not supported — no input redirection or " ..
				"backgrounding. `|` pipes, `;` `&&` `||` chain, `>` writes to a script.", arg)
		end
	end

	local statements = parseStatements(argv)
	if #statements == 0 then
		return ""
	end

	local outputs: { string } = {}
	local lastOk = true
	for index, statement in ipairs(statements) do
		local skip = (statement.joiner == "&&" and not lastOk)
			or (statement.joiner == "||" and lastOk)
		if not skip then
			-- A heredoc body belongs to the last statement, the way a shell
			-- attaches it to the command it followed.
			local output, ok = runPipeline(self, statement.stages, readOnly,
				index == #statements and stdin or nil)
			lastOk = ok
			if #statements == 1 then
				return output
			end
			-- With several commands the outputs need labelling, or there is no
			-- telling which block came from which.
			outputs[#outputs + 1] = string.format("$ %s\n%s", label(statement), output)
		end
	end
	return table.concat(outputs, "\n")
end

-- Self-test
-- Fails loudly if the tokenizer loses track of a quote, a flag form stops
-- parsing, a glob stops anchoring, or a handler throws on a bare invocation.
-- The API-dump half of this now lives in Props.selfTest.
function Shell.selfTest(probe: any): (boolean, string?)
	-- Tokenizer: `want` is nil where the line must be rejected.
	local cases: { { line: string, want: { string }? } } = {
		{ line = "ls /Workspace", want = { "ls", "/Workspace" } },
		{ line = "  cat   foo.luau  ", want = { "cat", "foo.luau" } },
		{ line = 'cd "My Model"', want = { "cd", "My Model" } },
		{ line = "cd 'My Model'", want = { "cd", "My Model" } },
		{ line = 'grep "os.clock()" /', want = { "grep", "os.clock()", "/" } },
		{ line = 'cd Parts/"Big Brick"', want = { "cd", "Parts/Big Brick" } },
		{ line = 'grep "say \\"hi\\""', want = { "grep", 'say "hi"' } },
		{ line = "cd Weird\\ Name", want = { "cd", "Weird Name" } },
		{ line = 'set /P Name ""', want = { "set", "/P", "Name", "" } },
		{ line = "", want = {} },
		{ line = 'cd "unclosed', want = nil },
		{ line = "grep it's", want = nil },
		-- A newline is a command separator, not an argument separator. Getting
		-- this wrong is silent: `ls` just swallows the next line's words.
		{ line = "ls /Workspace\ncat Main.luau",
		  want = { "ls", "/Workspace", ";", "cat", "Main.luau" } },
		{ line = "pwd\n\n\nls", want = { "pwd", ";", ";", ";", "ls" } },
		-- A quoted pipe is data, not a pipeline. This is the case a bug report
		-- claimed was broken; it never was, and a regression here would break
		-- every `grep -E` alternation, so it is worth pinning down.
		{ line = 'grep -E "a|b" /', want = { "grep", "-E", "a|b", "/" } },
		-- Inside double quotes a backslash only escapes " \ $ and `. Eating it
		-- indiscriminately turned `"^\t###"` into `^t###`, so the search ran
		-- against a pattern nobody wrote and returned a confident "no matches".
		{ line = 'grep -nE "^\\t###" f', want = { "grep", "-nE", "^\\t###", "f" } },
		{ line = 'echo "a\\$b"', want = { "echo", "a$b" } },
		{ line = 'echo "back\\\\slash"', want = { "echo", "back\\slash" } },
	}
	for _, case in ipairs(cases) do
		local got = tokenize(case.line)
		if case.want == nil then
			if got then
				return false, string.format("tokenize(%q) should have failed", case.line)
			end
		else
			if not got then
				return false, string.format("tokenize(%q) failed unexpectedly", case.line)
			end
			local gotStr = table.concat(got, "|")
			local wantStr = table.concat(case.want :: { string }, "|")
			if gotStr ~= wantStr then
				return false, string.format("tokenize(%q): got %s, want %s", case.line, gotStr, wantStr)
			end
		end
	end

	-- Flag forms all have to land on the same (path, count). `-n20` is the form
	-- that only works because a value letter swallows the rest of its token.
	for _, line in ipairs({ "head -n 20 /a", "head -n20 /a", "head -20 /a", "head /a 20",
		"head /a -n 20" }) do
		local argv = tokenize(line) :: { string }
		local _, values, operands = parse(argv)
		local path, count = takeCount(operands)
		count = numberOf(values, "-n") or count
		if path ~= "/a" or count ~= 20 then
			return false, string.format("%q parsed as (%s, %s)", line, tostring(path), tostring(count))
		end
	end

	-- Script suffixes. `ls` renders every script class as `.luau`, but a model
	-- writes whichever form it knows, and all of them have to land on the same
	-- instance: the class is a property in the DataModel, never part of a name.
	for _, case in ipairs({
		{ name = "Main.luau", want = "Main" },
		{ name = "Main.lua", want = "Main" },
		{ name = "Handler.server.luau", want = "Handler" },
		{ name = "Handler.client.lua", want = "Handler" },
		-- No suffix, and a name that is nothing but a suffix, both stay put.
		{ name = "Main", want = nil },
		{ name = ".luau", want = nil },
		}) do
		local got = Fs.stripScriptSuffix(case.name)
		if got ~= case.want then
			return false, string.format("stripScriptSuffix(%q) = %s, want %s",
				case.name, tostring(got), tostring(case.want))
		end
	end

	-- `workspace` is a Luau global, not the service's Name, so FindFirstChild
	-- misses it and every path a model writes lowercase used to fail, including
	-- `catalog parent workspace`, where the failure looked like a catalog bug.
	-- It has to hold from a cwd other than the root too, since `workspace` is a
	-- global everywhere in Luau and a model that cd'd somewhere still writes it.
	-- The non-root base is a detached fixture, not a real service: an assertion
	-- about what is *not* in the open place is an assertion about the user's
	-- game, and it would fail the moment someone named a Folder "workspace".
	local fixture = Instance.new("Folder")
	local nested = Instance.new("Folder")
	nested.Name = "nested"
	nested.Parent = fixture
	for _, base in ipairs({ game, fixture }) do
		for _, path in ipairs({ "workspace", "/workspace", "Workspace" }) do
			if Fs.resolve(base, path) ~= game:GetService("Workspace") then
				return false, string.format("resolve(%q) from %s did not reach Workspace",
					path, base.Name)
			end
		end
	end
	-- ...but only as the leading segment. Deeper in a path it is a child name.
	if Fs.resolve(fixture, "nested/workspace") ~= nil then
		return false, "workspace fallback fired on a non-leading segment"
	end
	-- And a real child by that name beats the fallback, wherever it sits.
	local impostor = Instance.new("Folder")
	impostor.Name = "workspace"
	impostor.Parent = fixture
	if Fs.resolve(fixture, "workspace") ~= impostor then
		return false, "workspace fallback shadowed a real child"
	end
	fixture:Destroy()

	-- Globs: a bare word stays a substring match, a wildcard anchors.
	for _, case in ipairs({
		{ pattern = "*Handler*", name = "DamageHandler", want = true },
		{ pattern = "Part*", name = "MyPart", want = false },
		{ pattern = "Handler", name = "DamageHandler", want = true },
		{ pattern = "*.luau", name = "Main.luau", want = true },
		{ pattern = "a.b", name = "axb", want = false },
		}) do
		if nameMatcher(case.pattern)(case.name) ~= case.want then
			return false, string.format("nameMatcher(%q)(%q) should be %s",
				case.pattern, case.name, tostring(case.want))
		end
	end

	-- The ls cap. A detached fixture rather than a real container, so the check
	-- asserts nothing about the user's place. Broken open, one `ls` of a big
	-- Workspace costs ~25 000 tokens for the rest of the session; broken shut, it
	-- truncates listings that were fine.
	local big = Instance.new("Folder")
	for i = 1, MAX_LIST + 5 do
		local part = Instance.new("Folder")
		part.Name = string.format("N%03d", i)
		part.Parent = big
	end
	local savedCwd = probe.cwd
	probe.cwd = big
	local bigOut = Shell.run(probe, "ls")
	local longOut = Shell.run(probe, "ls -l")
	probe.cwd = savedCwd
	big:Destroy()
	if not bigOut:match("… 5 more") then
		return false, "ls did not cap a listing of " .. tostring(MAX_LIST + 5)
	end
	-- The cut has to NAME where it started. Rows are sorted before the budget is
	-- spent, so truncation always eats the alphabetical tail, which is how the
	-- root listing quietly lost Workspace. A count alone reads as "the boring
	-- rest"; the name is what makes a missing entry visible.
	if not bigOut:match('from "N101" on') then
		return false, "capped ls did not name the first dropped entry:\n" ..
			bigOut:sub(-120)
	end
	-- ...and the root is exempt from the cap entirely, because every service is
	-- reachable-or-not, not merely interesting. Asserted against `game` itself
	-- rather than a fixture: this is the one listing whose completeness matters.
	local rootRows = #splitLines(Shell.run(probe, "ls /"))
	if rootRows ~= #game:GetChildren() then
		return false, string.format("ls / listed %d of %d services — the root must never be capped",
			rootRows, #game:GetChildren())
	end
	if #splitLines(bigOut) ~= MAX_LIST + 1 then
		return false, string.format("capped ls emitted %d lines, want %d",
			#splitLines(bigOut), MAX_LIST + 1)
	end
	-- Every row here is a childless Folder, so -l must print the class and stop.
	-- "0 children" lands on every row of every -l listing, so this is paid at
	-- scale; the `[Folder]` half pins that -l still formatted at all.
	if not longOut:find("N001 %[Folder%]") then
		return false, "ls -l did not format a row: " .. longOut:sub(1, 80)
	end
	if longOut:find("children") then
		return false, "ls -l printed a child count for a childless instance"
	end

	-- grep groups its hits under one header per script. The failure worth catching
	-- is a header emitted per hit, which is silent, the output still reads fine,
	-- it just costs what grouping was added to stop costing. -c and -l parse the
	-- ungrouped form, so they are pinned in the same breath.
	local grepFixture = Instance.new("Folder")
	for _, entry in ipairs({ { "A", "needle\nx\nneedle\n" }, { "B", "y\nneedle\n" } }) do
		local module = Instance.new("ModuleScript")
		module.Name = entry[1]
		module.Source = entry[2]
		module.Parent = grepFixture
	end
	probe.cwd = grepFixture
	local grepOut = Shell.run(probe, "grep needle")
	local grepCount = Shell.run(probe, "grep -c needle")
	local grepList = Shell.run(probe, "grep -l needle")
	probe.cwd = savedCwd
	grepFixture:Destroy()
	do
		local headers = select(2, grepOut:gsub("\n?/[AB]\n", ""))
		if headers ~= 2 then
			return false, string.format("grep emitted %d headers for 3 hits in 2 scripts, want 2:\n%s",
				headers, grepOut)
		end
	end
	if grepCount ~= "3" then
		return false, "grep -c returned " .. grepCount .. ", want 3 (grouping must run after -c)"
	end
	if #splitLines(grepList) ~= 2 then
		return false, "grep -l returned " .. grepList .. ", want 2 paths"
	end

	-- Reading a specific part of a file: the job the shell used to lose to the
	-- `run` tool, where a hand-written line splitter had an off-by-one that
	-- produced a false finding about two modules differing. These are the
	-- built-ins that make reaching for `run` unnecessary, so a regression here
	-- costs correctness somewhere else entirely.
	local textFixture = Instance.new("Folder")
	local sample = Instance.new("ModuleScript")
	sample.Name = "Sample"
	sample.Source = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
	sample.Parent = textFixture
	local cased = Instance.new("ModuleScript")
	cased.Name = "Cased"
	cased.Source = "Humanoid\nhumanoid\n"
	cased.Parent = textFixture
	-- Lexical and numeric order disagree here on purpose: 10 sorts before 2 as
	-- text, so `sort -n` doing nothing is visible rather than plausible.
	local nums = Instance.new("ModuleScript")
	nums.Name = "Nums"
	nums.Source = "10\n2\n30\n"
	nums.Parent = textFixture
	local dupes = Instance.new("ModuleScript")
	dupes.Name = "Dupes"
	dupes.Source = "a\na\nb\n"
	dupes.Parent = textFixture
	local mixed = Instance.new("ModuleScript")
	mixed.Name = "Mixed"
	mixed.Source = "B\na\n"
	mixed.Parent = textFixture
	-- A line built to make a nested quantifier blow up: every prefix of the a's
	-- can be split between the inner and outer loop, and the final `!` means no
	-- arrangement ever satisfies `$`. Unbounded, this is a frozen Studio.
	local runaway = Instance.new("ModuleScript")
	runaway.Name = "Runaway"
	runaway.Source = string.rep("a", 40) .. "!\n"
	runaway.Parent = textFixture
	probe.cwd = textFixture

	local checks: { { line: string, want: string, why: string } } = {
		{ line = "sed -n '2,4p' Sample.luau", want = "beta\ngamma\ndelta",
		  why = "sed address range" },
		{ line = "sed -n '3p' Sample.luau", want = "gamma", why = "single-line address" },
		{ line = "sed -n '4,$p' Sample.luau", want = "delta\nepsilon", why = "$ is the last line" },
		-- -c is BYTES. Silently treated as -n, it returned ~1500 characters to
		-- someone asking for 50 precisely to avoid flooding their context.
		{ line = "head -c 5 Sample.luau", want = "alpha", why = "head -c counts bytes" },
		{ line = "tail -c 8 Sample.luau", want = "epsilon\n", why = "tail -c counts bytes" },
		-- A number, not "5 lines". Prose composes with nothing.
		{ line = "wc -l Sample.luau", want = "5", why = "wc -l returns a number" },
		{ line = "wc -w Sample.luau", want = "5", why = "wc -w returns a number" },
		-- The headline complaint: this used to report `no child named "3"`,
		-- blaming the argument for the flag's absence.
		{ line = "grep -A 1 beta Sample.luau", want = "/Sample\n  2: beta\n  3- gamma",
		  why = "grep -A trailing context" },
		{ line = "grep -B1 delta Sample.luau", want = "/Sample\n  3- gamma\n  4: delta",
		  why = "grep -B, count glued to the flag" },
		-- Bundled with a bool flag ahead of it. This used to be REFUSED outright
		-- "give -A/-B/-C their own argument", because the old partition returned a
		-- flag set with nowhere to put the 3, so `-nA3` was indistinguishable from
		-- the three flags -n -A -3. A value letter ending its bundle fixes the
		-- whole class, which is what the rest of the flag coverage rests on.
		{ line = "grep -nA1 beta Sample.luau", want = "/Sample\n  2: beta\n  3- gamma",
		  why = "grep -A bundled behind another flag" },
		{ line = "grep -C 1 gamma Sample.luau",
		  want = "/Sample\n  2- beta\n  3: gamma\n  4- delta", why = "grep -C both sides" },
		{ line = "grep Humanoid Cased.luau", want = "/Cased\n  1: Humanoid",
		  why = "grep is case-sensitive" },
		{ line = "grep -ci Humanoid Cased.luau", want = "2", why = "grep -i" },
		{ line = "grep -cE '[a-z]+' Sample.luau", want = "5", why = "-E is a real character class" },
		-- Alternation and {n,m} were HARD ERRORS under the old translation layer.
		-- They are the two constructs a reviewer called non-negotiable, and the
		-- clearest proof the engine underneath changed.
		{ line = "grep -cE 'alpha|delta' Sample.luau", want = "2", why = "-E alternation" },
		{ line = "grep -cE '^[a-z]{5}$' Sample.luau", want = "3", why = "-E interval" },
		{ line = "grep -oE 'l+' Cased.luau", want = "no matches", why = "-o with no hit" },
		-- Backreference: `(.)\1` finds a doubled letter. Nothing in a Lua pattern
		-- can express this, so it only passes with a real engine behind it.
		{ line = "grep -cE '(.)\\1' Dupes.luau", want = "0", why = "-E backreference" },
		-- Plain grep is BRE now, so a dot is a metacharacter here exactly as it is
		-- in every other grep, and `\.` is how you ask for a literal one.
		{ line = "grep -c 'g.mma' Sample.luau", want = "1", why = "plain grep is BRE, . is any char" },
		{ line = "grep -c 'g\\.mma' Sample.luau", want = "0", why = "BRE \\. is a literal dot" },
		-- In BRE `+` is literal text and `\+` is the quantifier. Getting this
		-- backwards is the single most likely way to break the dialect switch.
		{ line = "grep -c 'alpha\\+' Sample.luau", want = "1", why = "BRE \\+ is one-or-more" },
		{ line = "grep -c 'alpha+' Sample.luau", want = "0", why = "BRE bare + is literal" },
		-- A quoted metacharacter is a one-character pattern, not a redirection.
		{ line = 'echo "<"', want = "<", why = "quoted metacharacter is data" },

		-- ---- flags added with the spec mechanism -------------------------------
		-- Every one of these is a flag that used to be either refused or, worse,
		-- accepted and ignored. An ignored flag is the failure this whole change
		-- exists to remove, and it is invisible without an exact-output check.

		-- head/tail signs. Losing the sign turns either into a plain count, which
		-- returns real lines from the wrong end of the file.
		{ line = "head -n -2 Sample.luau", want = "alpha\nbeta\ngamma",
		  why = "head -n -N is all but the last N" },
		{ line = "tail -n +4 Sample.luau", want = "delta\nepsilon",
		  why = "tail -n +N is from line N" },
		-- Several operands. Both used to read only the first and say nothing.
		{ line = "head -n 1 Sample.luau Cased.luau",
		  want = "==> /Sample <==\nalpha\n\n==> /Cased <==\nHumanoid",
		  why = "head reads every operand, with headers" },
		{ line = "wc -l Sample.luau Cased.luau", want = "5  /Sample\n2  /Cased\n7  total",
		  why = "wc totals across operands" },
		{ line = "wc -m Cased.luau", want = "18", why = "wc -m counts characters" },
		{ line = "wc -L Sample.luau", want = "7", why = "wc -L is the longest line" },

		-- grep: -e takes a value and repeats, which is also the alternation
		-- luaPattern has to refuse. -w/-x wrap, -o extracts, -m caps, -q is silent.
		{ line = "grep -c -e alpha -e beta Sample.luau", want = "2",
		  why = "repeated -e is a union" },
		{ line = "grep -o -e mano Cased.luau", want = "/Cased\n  1: mano\n  2: mano",
		  why = "grep -o emits the match, not the line" },
		{ line = "grep -cw Humanoid Cased.luau", want = "1", why = "grep -w is a whole word" },
		{ line = "grep -cx humanoid Cased.luau", want = "1", why = "grep -x is the whole line" },
		-- 'a' is on four of the five lines, so -m 1 doing nothing would read as 4.
		{ line = "grep -c a Sample.luau", want = "4", why = "grep -c counts every match" },
		{ line = "grep -c -m 1 a Sample.luau", want = "1", why = "grep -m caps matches per file" },
		{ line = "grep -q alpha Sample.luau", want = "", why = "grep -q prints nothing" },
		{ line = "grep -h alpha Sample.luau", want = "1: alpha", why = "grep -h drops the path" },

		-- cat display flags.
		{ line = "cat -n Cased.luau", want = "     1\tHumanoid\n     2\thumanoid",
		  why = "cat -n numbers lines" },
		{ line = "cat -E Cased.luau", want = "Humanoid$\nhumanoid$", why = "cat -E marks line ends" },

		-- sort/uniq beyond -r and -u.
		{ line = "sort -n Nums.luau", want = "2\n10\n30", why = "sort -n is numeric, not lexical" },
		{ line = "sort Nums.luau", want = "10\n2\n30", why = "sort without -n is lexical" },
		-- "B" sorts before "a" by byte and after it by letter, so this is one of
		-- the few inputs where -f doing nothing is visible rather than plausible.
		{ line = "sort Mixed.luau", want = "B\na", why = "sort is byte order by default" },
		{ line = "sort -f Mixed.luau", want = "a\nB", why = "sort -f folds case" },
		{ line = "uniq -c Dupes.luau", want = "   2 a\n   1 b", why = "uniq -c counts a run" },
		{ line = "uniq -d Dupes.luau", want = "a", why = "uniq -d keeps only repeats" },
		{ line = "uniq -u Dupes.luau", want = "b", why = "uniq -u keeps only singles" },

		-- tr: escapes, classes, and the one-set flags. `tr -d '\n'` failed three
		-- ways over, the escape was not understood, two sets were required, and
		-- the filter ran per line so "\n" was unreachable even once parsed. tr is
		-- a byte filter, so unlike sed/head it keeps the trailing newline.
		{ line = "tr -d '\\n' Cased.luau", want = "Humanoidhumanoid", why = "tr -d with an escape" },
		{ line = "tr -d '[:upper:]' Cased.luau", want = "umanoid\nhumanoid\n",
		  why = "tr POSIX character class" },
		{ line = "tr a-z A-Z Cased.luau", want = "HUMANOID\nHUMANOID\n", why = "tr translates ranges" },
		-- Through a pipe, because the squeeze needs an adjacent run to collapse.
		{ line = "echo aaab | tr -s a", want = "ab", why = "tr -s squeezes a run" },
		{ line = "echo abc | tr -d b", want = "ac", why = "tr -d takes one set" },

		-- sed commands beyond substitution.
		{ line = "sed '2d' Sample.luau", want = "alpha\ngamma\ndelta\nepsilon", why = "sed d deletes" },
		{ line = "sed -n '/gam/p' Sample.luau", want = "gamma", why = "sed /pattern/ address" },
		{ line = "sed -e '1d' -e '$d' Sample.luau", want = "beta\ngamma\ndelta",
		  why = "repeated -e runs in order" },
		{ line = "sed '1d;$d' Sample.luau", want = "beta\ngamma\ndelta",
		  why = "one -e can carry several commands" },
		{ line = "sed 'y/ae/AE/' Cased.luau", want = "HumAnoid\nhumAnoid", why = "sed y transliterates" },
		-- sed's replacement syntax is sed's, not Lua's: \1 for a group and & for
		-- the whole match. `%1` was the old dialect and is now just two characters.
		{ line = "sed -E 's/(al)(pha)/\\2\\1/' Sample.luau",
		  want = "phaal\nbeta\ngamma\ndelta\nepsilon", why = "sed \\1 backreferences" },
		{ line = "sed 's/beta/[&]/' Sample.luau",
		  want = "alpha\n[beta]\ngamma\ndelta\nepsilon", why = "sed & is the whole match" },
		{ line = "sed 's/beta/[\\&]/' Sample.luau",
		  want = "alpha\n[&]\ngamma\ndelta\nepsilon", why = "sed \\& is a literal ampersand" },
		-- BRE in sed too: bare + is text, \+ is the quantifier.
		{ line = "sed 's/l\\+/L/' Sample.luau",
		  want = "aLpha\nbeta\ngamma\ndeLta\nepsiLon", why = "sed is BRE by default" },
		-- The s/// suffix flags. `p` was parsed and then dropped, so the standard
		-- "print only what changed" idiom printed nothing at all.
		{ line = "echo test | sed 's/test/X/p'", want = "X\nX",
		  why = "s///p prints again on top of the auto-print" },
		{ line = "echo test | sed -n 's/test/X/p'", want = "X",
		  why = "-n with s///p is the only-changed-lines idiom" },
		{ line = "echo test | sed -n 's/nope/X/p'", want = "",
		  why = "s///p stays silent when nothing changed" },
		-- A number picks which occurrence; g from there on.
		{ line = "echo aaa | sed 's/a/X/2'", want = "aXa", why = "s///N is the Nth match" },
		{ line = "echo aaa | sed 's/a/X/2g'", want = "aXX", why = "s///Ng is Nth onwards" },
		{ line = "sed -n '$=' Sample.luau", want = "5", why = "sed = prints the line number" },

		-- basename/dirname.
		{ line = "basename /a/b/Main.luau .luau", want = "Main", why = "basename strips a suffix" },
		{ line = "basename -a /a/x /b/y", want = "x\ny", why = "basename -a takes several" },
		{ line = "dirname /a/b/c", want = "/a/b", why = "dirname" },

		-- echo had no spec at all, so -n arrived as data and was printed.
		{ line = "echo -n hi", want = "hi", why = "echo -n is a flag, not a word" },
		{ line = "echo -e 'a\\tb'", want = "a\tb", why = "echo -e expands escapes" },
		-- ...and then it got a spec, which broke the opposite case: for echo a
		-- leading dash is usually DATA, and the generic gate refused it. Only an
		-- exact -n/-e/-E is a flag; everything else prints.
		{ line = 'echo "---"', want = "---", why = "echo prints a dashed word" },
		{ line = "echo -x", want = "-x", why = "echo only treats -n/-e/-E as flags" },
		{ line = "echo -n -- -n", want = "-- -n", why = "the first non-flag stops flag parsing" },

		-- find matching a name has to try the DISPLAYED name too: `ls` prints a
		-- script as Main.luau, so a model that read a listing searches *.luau, and
		-- no instance name has ever contained that suffix. This calls displayName,
		-- which was missing from the aliases at the top of this file and so was a
		-- nil global: `find -name` threw instead of matching.
		-- Counted rather than listed: find walks GetChildren() order, so asserting
		-- the exact list would pin creation order rather than the match.
		{ line = "find . -name '*.luau' | wc -l", want = "6",
		  why = "find -name matches the .luau display name" },
		{ line = "find . -name Sample", want = "/Sample  [ModuleScript]",
		  why = "find -name matches the real name" },

		-- egrep is grep -E by definition, not an alias that shares a handler.
		-- Sharing it meant a bracket class searched for its own six characters
		-- and reported "no matches", which reads as "there are no digits here".
		-- The three names, three dialects: egrep is ERE, plain grep is BRE (where
		-- `[a-z]` is a class but `+` is literal text, so this finds nothing), and
		-- fgrep is fixed strings.
		{ line = "egrep -c '[a-z]+' Sample.luau", want = "5", why = "egrep is ERE" },
		{ line = "grep -c '[a-z]+' Sample.luau", want = "0", why = "plain grep is BRE, + is literal" },
		{ line = "fgrep -c '[a-z]+' Sample.luau", want = "0", why = "fgrep is always literal" },

		-- Zero lines is a real request. `head -0` used to fall through to the
		-- path list and report `no child named "-0"`, while -1 and up worked.
		{ line = "head -0 Sample.luau", want = "", why = "head -0 is a count, not a path" },
		{ line = "tail -0 Sample.luau", want = "", why = "tail -0 is a count, not a path" },
		{ line = "head -1 Sample.luau", want = "alpha", why = "head -1 still works" },
	}
	local failure: string? = nil
	for _, check in ipairs(checks) do
		local got = Shell.run(probe, check.line)
		if got ~= check.want then
			failure = string.format("%s — %q returned %q, want %q",
				check.why, check.line, got, check.want)
			break
		end
	end

	-- Failures that must NAME themselves. Every one of these used to be a silent
	-- wrong answer or an error pointing at the wrong thing.
	if not failure then
		for _, case in ipairs({
			{ line = "grep -Z needle Sample.luau", want = "line%-oriented" },
			{ line = "head -Q Sample.luau", want = "unsupported flag %-Q" },
			-- A value flag whose value is not a number must say so. Falling back to
			-- 0 would print no context at all, which reads as "there was none".
			{ line = "grep -A x beta Sample.luau", want = "needs a number" },
			-- ...and one with no value left to take at all.
			{ line = "grep -n -A", want = "needs a value" },
			-- Refusals that must carry the DataModel reason rather than a list of
			-- what is allowed. Each of these is a flag someone will reach for on
			-- reflex, and "unsupported" alone does not say which part of the idea
			-- was wrong, whether to rephrase it or to stop asking.
			{ line = "ls -o /", want = "no owner" },
			{ line = "ls -u /", want = "records a read" },
			{ line = "ls -L /", want = "ObjectValue" },
			-- Matches the load-bearing half of the reason. The wording moved once
			-- already: it used to claim yielding stalls SSE parsing, which is not
			-- true: what rules -f out is that it never RETURNS.
			{ line = "tail -f Sample.luau", want = "never returns" },
			{ line = "find / -exec ls", want = "`run` tool" },
			{ line = "find / -user me", want = "no owner" },
			{ line = "cp -l a b", want = "exactly one Parent" },
			{ line = "mv -i a b", want = "nobody at a terminal" },
			{ line = "chmod 755 Sample.luau", want = "user/group/other" },
			{ line = "ln Sample.luau Other", want = "exactly one Parent" },
			{ line = "chown me Sample.luau", want = "no owner" },
			-- -size without a unit is bytes here, not 512-byte blocks; a bad
			-- argument has to say so rather than compare against nothing.
			{ line = "find / -size zz", want = "%-size takes a number" },
			-- Several sources need a real container, or all but the last are lost.
			{ line = "mv Sample.luau Cased.luau Nope", want = "not an existing container" },
			-- An invalid pattern must be REFUSED at compile, before any line runs.
			-- The old layer refused valid regex instead, which is the inverse.
			{ line = 'grep -E "(ab" Sample.luau', want = "unmatched" },
			{ line = 'grep -E "[a-" Sample.luau', want = "unterminated" },
			{ line = 'grep -P "(?<=x)y" Sample.luau', want = "lookbehind" },
			-- Catastrophic backtracking has to come back as an error. Unbounded,
			-- this would not be a slow grep. Luau cannot preempt, so it would
			-- freeze Studio with no way out.
			{ line = 'grep -E "(a+)+$" Runaway.luau', want = "too expensive" },
			-- An unknown s/// suffix used to be swallowed whole: `s/x/y/qqqzzz`
			-- reported success and did the substitution anyway.
			{ line = "echo test | sed 's/test/X/qqq'", want = "unknown flag" },
			-- rm and rmdir both recursed into a full container without saying so.
			-- rmdir sharing rm's handler made it a silent `rm -r`, which is the
			-- egrep-shares-grep defect again, except this one destroys things.
			{ line = "rm .", want = "use %-r" },
			{ line = "rmdir .", want = "not empty" },
			{ line = "sed -n '9,2p' Sample.luau", want = "empty range" },
			-- A malformed pattern used to leave every line unmodified and report
			-- success: invisible under -i, where the write lands and changes
			-- nothing. The only silent failure on a path that writes.
			{ line = "sed 's/[/x/' Sample.luau", want = "sed:" },
			{ line = "grep zzz Cased.luau", want = "no matches" },
			-- The case-sensitivity change has exactly one regression shape: a
			-- search that used to work now finds nothing. It has to say so.
			{ line = "grep HUMANOID Cased.luau", want = "grep %-i" },
		}) do
			local got = Shell.run(probe, case.line)
			if not got:match(case.want) then
				failure = string.format("%q returned %q, want a message matching %q",
					case.line, got, case.want)
				break
			end
		end
	end

	probe.cwd = savedCwd
	textFixture:Destroy()
	if failure then
		return false, failure
	end

	-- Editor-aware source access. `.Source` is no longer the whole truth. Roblox
	-- decoupled the script editor from it, so reads and writes now go through
	-- the editor when a document is open. A DETACHED fixture is never open, so
	-- everything here must take the plain .Source path, which is also what keeps
	-- the entire checks table above meaningful.
	local sourceFixture = Instance.new("ModuleScript")
	sourceFixture.Name = "SourceProbe"
	sourceFixture.Source = "alpha\n"
	local sourceFailure: string? = nil
	repeat
		if Fs.openDocument(sourceFixture) ~= nil then
			sourceFailure = "a detached script reported an open editor document"
			break
		end
		if getSource(sourceFixture) ~= "alpha\n" then
			sourceFailure = "getSource did not fall back to .Source for a closed script"
			break
		end
		-- CRLF is folded at the write seam. UpdateSourceAsync is documented to do
		-- nothing when ONLY the line endings changed, and to error outright on a
		-- carriage return with Live Scripting on; normalising removes both, and a
		-- regression here is silent, the write reports success and does nothing.
		local writeErr = Fs.writeSource(sourceFixture, "a\r\nb\r\n")
		if writeErr then
			sourceFailure = "writeSource failed: " .. writeErr
			break
		end
		if getSource(sourceFixture) ~= "a\nb\n" then
			sourceFailure = string.format("CRLF was not normalised: %q",
				tostring(getSource(sourceFixture)))
			break
		end
		-- A byte-identical write is skipped rather than sent, for that same bug.
		if Fs.writeSource(sourceFixture, "a\r\nb\r\n") ~= nil then
			sourceFailure = "an identical write reported an error"
			break
		end
		if getSource(sourceFixture) ~= "a\nb\n" then
			sourceFailure = "an identical write changed the source"
			break
		end
	until true
	sourceFixture:Destroy()
	if sourceFailure then
		return false, sourceFailure
	end

	-- openDocuments must not throw, and must assert NOTHING about what is open:
	-- the user may legitimately have half the place open when the plugin loads.
	-- The contract is the shape, not the contents.
	if type(Fs.openDocuments()) ~= "table" then
		return false, "Fs.openDocuments did not return a table"
	end

	-- COMMANDS is derived from HANDLERS now, so it cannot drift. What this
	-- catches is a handler that throws on a bare invocation. Safe to run: every
	-- command that mutates (rm, mv, cp, set, new, mkdir, touch, ln) needs a path
	-- and bails before touching anything, and the rest just read the cwd.
	for _, name in ipairs(COMMANDS) do
		local ok, result = pcall(function()
			return Shell.run(probe, name)
		end)
		if not ok then
			return false, string.format("shell(%q) threw: %s", name, tostring(result))
		end
		if (result :: string):match("^bash: unknown command") then
			return false, "COMMANDS lists a command with no handler: " .. name
		end
	end
	if not Shell.run(probe, "chown me /Workspace"):match("no owner") then
		return false, "UNSUPPORTED lookup is not firing"
	end

	-- Every declared flag must be REACHABLE. This is the mechanical half of the
	-- `rm -rf` bug: the letters were declared, `rm -r x` parsed cleanly, and the
	-- -r was dropped on the floor with nothing in the output to say so. A spec
	-- that contradicts itself, a letter both offered and refused, or a `why` for
	-- a flag that is actually accepted, produces exactly that shape of silence,
	-- so it is checked here rather than trusted to review.
	for name, spec in pairs(SPECS) do
		local declared = (spec.bool or "") .. (spec.value or "")
		for letter in declared:gmatch(".") do
			if spec.why and spec.why["-" .. letter] then
				return false, string.format(
					"%s declares -%s as both a flag and a refusal — one of them never fires",
					name, letter)
			end
			-- Parsed, not run: several of these need operands, and the point is
			-- only that the gate lets the letter through on its own terms.
			local argv = { name, "-" .. letter, "1" }
			local _, _, _, err = partition(argv, spec)
			if err then
				return false, string.format("%s -%s is declared but rejected: %s",
					name, letter, err)
			end
		end
		for flag in pairs(spec.why or {}) do
			local letter = flag:sub(2)
			if declared:find(letter, 1, true) and #flag == 2 then
				return false, string.format("%s refuses %s but also offers it", name, flag)
			end
		end
		-- A long option pointing at a short flag the command does not declare
		-- would set a flag no handler reads, the same silence in a new shape.
		for long, declaredKind in pairs(spec.long or {}) do
			local short = declaredKind:match(":(%-.+)$")
			if short and not declared:find(short:sub(2), 1, true) then
				return false, string.format("%s maps %s to %s, which it does not declare",
					name, long, short)
			end
		end
	end

	-- Stderr redirections must be swallowed rather than rejected. `&` is a
	-- metacharacter, so before these were stripped a trailing `2>&1`, about the
	-- most reflexive thing there is to append to a command, failed the line.
	for _, line in ipairs({ "pwd 2>&1", "pwd 2>/dev/null", "pwd &>/dev/null", "pwd 1>&2" }) do
		local out = Shell.run(probe, line)
		if out:match("not supported") or out:match("unknown command") then
			return false, string.format("%q was rejected: %s", line, out)
		end
	end

	-- `which` answers about commands, not about instances that share a name.
	if not Shell.run(probe, "which grep"):match("builtin") then
		return false, "which does not recognise a shell builtin"
	end
	if not Shell.run(probe, "which edit"):match("separate tool") then
		return false, "which does not recognise a tool"
	end

	-- One flag can turn an allowlisted read-only command into a mutating one, and
	-- /sh exists so that every mutation arrives through Claude with an undo
	-- recording attached. Each of these has to be refused however the allowlist
	-- reads, including with the flag bundled or its value glued on.
	for _, line in ipairs({
		"sed -i s/a/b/ x.luau", "sed -in s/a/b/ x.luau",
		"sort -o out.luau x.luau", "sort -oout.luau x.luau",
		"find / -name X -delete",
	}) do
		if not Shell.run(probe, line, true):match("read%-only") then
			return false, "not blocked in read-only mode: " .. line
		end
	end
	-- chmod writes, so it must not be on the read-only allowlist at all.
	if not Shell.run(probe, "chmod +x x.luau", true):match("read%-only") then
		return false, "chmod is not blocked in read-only mode"
	end

	-- The observed-mtime journal. There is no timestamp on an Instance, so this
	-- is the only thing -t, -newer and -mmin have to sort on, and the case that
	-- must not regress is the UNOBSERVED one, which has to render as "-" and sort
	-- last rather than being reported as the oldest.
	--
	-- Names chosen so neither is a substring of the other: "Seen"/"Unseen" made
	-- the first assertion below pass even when the order was wrong, because
	-- ("Unseen"):match("Seen") is true. A test that cannot fail is worse than none.
	local timeFixture = Instance.new("Folder")
	local seen = Instance.new("ModuleScript")
	seen.Name = "Edited"
	seen.Parent = timeFixture
	local unseen = Instance.new("ModuleScript")
	unseen.Name = "Never"
	unseen.Parent = timeFixture
	-- Fs.watch's DescendantAdded would stamp both if this fixture were parented
	-- into the DataModel; detached, neither has a time until one is set here.
	Fs.touch(seen, 1000)
	probe.cwd = timeFixture
	local timeOut = Shell.run(probe, "ls -lt")
	probe.cwd = savedCwd
	timeFixture:Destroy()
	do
		local rows = splitLines(timeOut)
		if not (rows[1] or ""):match("Edited") then
			return false, "ls -t did not put the observed instance first:\n" .. timeOut
		end
		if not (rows[2] or ""):match("Never") then
			return false, "ls -t did not put the unobserved instance last:\n" .. timeOut
		end
		if not (rows[2] or ""):match("%-$") then
			return false, "ls -lt must render an unobserved mtime as '-', got:\n" .. timeOut
		end
	end

	-- -type has to reject a name that is not a class. IsA() cannot do this, it
	-- returns false rather than throwing, so a regression here shows up as a
	-- bare "no matches" and nothing else, which is indistinguishable from a
	-- pattern that genuinely matched nothing.
	local badType = Shell.run(probe, "find / -type file -name Anything")
	if not badType:match("not a class name") then
		return false, "find -type accepted a non-class: " .. badType
	end
	-- ...while the two aliases that DO map to real classes still work.
	for _, alias in ipairs({ "f", "d" }) do
		local ok, result = pcall(function()
			return Shell.run(probe, "find / -maxdepth 1 -type " .. alias .. " -name Zzz")
		end)
		if not ok or (result :: string):match("not a class name") then
			return false, "find -type " .. alias .. " was rejected: " .. tostring(result)
		end
	end

	-- diff has to ALIGN, not compare by position. The old version walked both
	-- files by index, so inserting one line at the top reported every following
	-- line as changed, 800 lines of "difference" for a one-line edit, and wrong
	-- about which line it was. This is the case that distinguishes the two.
	local diffFixture = Instance.new("Folder")
	local before = Instance.new("ModuleScript")
	before.Name = "Before"
	before.Source = "local a = 1\nlocal b = 2\nlocal c = 3\n"
	before.Parent = diffFixture
	local after = Instance.new("ModuleScript")
	after.Name = "After"
	after.Source = "-- new\nlocal a = 1\nlocal b = 2\nlocal c = 3\n"
	after.Parent = diffFixture
	probe.cwd = diffFixture
	local diffOut = Shell.run(probe, "diff Before.luau After.luau")
	local diffBrief = Shell.run(probe, "diff -q Before.luau After.luau")
	local diffSame = Shell.run(probe, "diff Before.luau Before.luau")
	probe.cwd = savedCwd
	diffFixture:Destroy()
	do
		local added, removed = 0, 0
		for _, line in ipairs(splitLines(diffOut)) do
			if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
				added += 1
			elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
				removed += 1
			end
		end
		if added ~= 1 or removed ~= 0 then
			return false, string.format(
				"diff reported +%d/-%d for a single inserted line, want +1/-0:\n%s",
				added, removed, diffOut)
		end
		if not diffOut:match("@@") then
			return false, "diff did not emit a unified hunk header:\n" .. diffOut
		end
	end
	if not diffBrief:match("differ") then
		return false, "diff -q did not report a difference: " .. diffBrief
	end
	if diffSame ~= "" then
		return false, "diff of a file against itself must be empty, got: " .. diffSame
	end

	return true, nil
end

return Shell
