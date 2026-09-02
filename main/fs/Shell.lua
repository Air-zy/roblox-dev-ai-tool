--!optimize 2
-- Shell.luau: the command line: parsing, composition, and the command table.
--
-- Split from Terminal on the seam that was already there. Terminal knows how to
-- do things to the DataModel, list a container, read a script's source, clone
-- an instance. This file knows how to read a line someone typed and work out
-- which of those to call, in what order, with what plumbed into what: quoting,
-- heredocs, `|` pipelines, `;` `&&` `||` chaining, `>` redirection, globs,
-- `for f in WORDS; do ... ; done` and `$(...)`.
--
-- The two halves change for unrelated reasons, which is why they are two files.
-- A new command is a HANDLERS entry; a new piece of syntax is a change here and
-- nowhere else.
--
-- It is still not a general shell interpreter, and the line is worth stating
-- because it has moved twice: there is no `if`, no `while`, no assignment, no
-- `$?`, no environment and no arithmetic, and the only variable is a loop's own.
-- Anything that needs more than that should use the `run` tool instead of
-- growing a language here.

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
-- Object ids, the path mapping and the working-tree walk. Everything git knows
-- that is not a request lives there; the requests stay here beside curl's, so
-- there is one place that knows what RequestAsync will send.
local Git = require(script.Parent.Parent:WaitForChild("git"):WaitForChild("Git"))

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
-- ponytail: no assignment, no `$?`, no arithmetic and no backticks, and no
-- reason to add them — anything that needs those should use `run`. Ceiling: the
-- quote/escape rules are bash's, but the grammar is hand-rolled rather than
-- parsed, and both `for` and `$(...)` were fitted onto it a pass at a time. A
-- real grammar is the upgrade path if a third one comes along.
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
			-- A backslash literalises exactly the way a quote does, and the flag is
			-- what says so downstream. Without this, `\;` `\|` `\>` produced tokens
			-- byte-identical to the OPERATORS and nothing could tell them apart:
			-- `find . -exec cat {} \;` had its statement cut at the `\;`, and
			-- `echo \> f.luau` was §3.10 all over again — the arrow taken as a
			-- redirection, the argument dropped and f.luau truncated.
			sawQuote = true
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
		elseif c == ">" then
			-- A redirection operator is a word delimiter in bash whether or not it
			-- is glued to what precedes it. Here it was an ordinary character, so
			-- `echo hi>f.luau` tokenized as the single word `hi>f.luau` and printed
			-- it: a redirect that wrote nothing, reported nothing, and produced
			-- output that looked like it had worked. `echo hi> f.luau` was the same
			-- failure with a space in it. Only the fully-spaced `echo hi > f.luau`
			-- and the `>f.luau` form ever landed.
			--
			-- A bare `1` or `2` immediately in front of the arrow is part of the
			-- OPERATOR, not an operand. Without that clause this fix would break
			-- something worse than it repaired: `find x 2>/dev/null` would split
			-- into `2` — searched for as a name — and a `>` aimed at /dev/null,
			-- which silently discards the real output. Only an unquoted digit, so
			-- `echo "2">f` still echoes the character.
			local pending = table.concat(buf)
			local stream = ""
			if not sawQuote and (pending == "1" or pending == "2") then
				stream = pending
				buf = {}
			end
			flush()
			local arrow = ">"
			if line:sub(i + 1, i + 1) == ">" then
				arrow = ">>"
				i += 1
			end
			args[#args + 1] = stream .. arrow
		elseif c == "<" then
			-- Same delimiter rule as `>`, and it needs no stream digit or doubled
			-- form: `2<` is not a thing anyone writes, and `<<` never reaches here
			-- because extractHeredoc lifts every heredoc off the line before
			-- tokenizing and refuses a `<<` it cannot find a delimiter for.
			flush()
			args[#args + 1] = "<"
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
		-- A negative NUMBER is an operand, never a flag: `head -20` is a count and
		-- `seq 5 -1 1` is a step. The guard used to read `^%-%d+$`, integers only,
		-- so `seq 2 -0.5 0` was taken apart into the flags -0, -. and -5. Nothing
		-- declares a digit or a dot as a flag, so widening it can only move a
		-- number out of the flag path and into the operands where it belongs.
		elseif #arg > 1 and arg:sub(1, 1) == "-" and not arg:match("^%-%d*%.?%d+$") then
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

-- Pull redirection out of argv: `> path`, `>> path`, `2> path`, glued or spaced.
--
-- `2>` USED to be recognised and thrown away, on the reasoning that there is no
-- stderr stream to aim it at. Recognising it was necessary — otherwise the token
-- falls through as a positional argument and `find x 2>/dev/null` searches for
-- an instance literally named "2>/dev/null" — but throwing it away made
-- `2>/dev/null` a lie: the most reflexive way there is to quiet a probe, quietly
-- doing nothing, with the noise still in the output.
--
-- There is still no stderr STREAM, and there does not need to be one. `failed`
-- already means "this errored and its whole output is the message" — that is the
-- invariant the pipeline is built on — so when a command fails, its output IS
-- stderr, and a `2>` target is somewhere to send it. Errors are the only thing
-- that goes there; a command that succeeded has nothing for it.
--
-- `&>` is rewritten to `>` before tokenizing and never reaches here: both streams
-- to one place is what already happens.
local function takeRedirect(argv: { string }): ({ string }, string?, boolean, string?, boolean, string?)
	local kept: { string } = {}
	local target: string? = nil
	local append = false
	local errTarget: string? = nil
	local errAppend = false
	local inTarget: string? = nil
	-- Which positions came out of quotes, tagged on by parseStatements. A quoted
	-- `>` is a one-character ARGUMENT — `grep '>' f.luau` searches for it — and
	-- reading it as an operator dropped the pattern and truncated the file being
	-- searched, in silence. Same rule the METACHARACTERS gate applies to `<`.
	local wasQuoted = (argv :: any).quoted or {}
	local i = 1
	while i <= #argv do
		local arg = argv[i]
		-- `glued` is always empty now that tokenize splits `>` off its own word,
		-- and it is still read: this has to keep working on an argv assembled
		-- anywhere other than the tokenizer, and a match that silently ignored
		-- the tail would take the NEXT operand as the path instead.
		local stream, arrow, glued = arg:match("^([12&]?)(>>?)(.*)$")
		if arrow and wasQuoted[i] then
			arrow = nil
		end
		if arg == "<" and not wasQuoted[i] then
			-- `wc -l < f.luau`. The path is the next word; tokenize has already
			-- split `<` off whatever it was glued to.
			inTarget = argv[i + 1] or ""
			i += 1
		elseif arrow then
			local path = glued
			if path == "" then
				path = argv[i + 1] or ""
				i += 1
			end
			if stream == "2" then
				errAppend = arrow == ">>"
				errTarget = path
			elseif stream ~= "&" then
				append = arrow == ">>"
				target = path
			end
		else
			kept[#kept + 1] = arg
		end
		i += 1
	end
	return kept, target, append, errTarget, errAppend, inTarget
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
	man = "no man pages; `help` lists the commands and `help NAME` gives one's flags",
	-- Reached from two directions and neither of them wants the full command
	-- list: a model typing it has finished and thinks it has to close something,
	-- and a person typing it has left shell mode already or is not in it. Named
	-- so both get one line instead of thirty-five.
	exit = "nothing to exit — there is no session here; `exit` on its own line " ..
		"leaves the widget's shell mode, and a tool call simply ends when it returns",
	quit = "nothing to quit; see `exit`",
	-- Generates completions, and nothing here completes: no terminal, no tab. Its
	-- one useful action, "what commands exist", is what `help` answers. Named
	-- rather than left to "unknown command" because a model reaching for it wants
	-- that list and would otherwise get it by accident, from a failure.
	compgen = "no completion here; `help` lists the commands and `help NAME` gives one's flags",
	-- Named with their replacements, because both are reached for as the fallback
	-- after something else was missing, and the answer nobody wants there is "use
	-- the run tool", which executes arbitrary Luau at plugin permission to do what
	-- a pipe already does. curl and wget were on this list for the same reason
	-- until they became commands.
	awk = "no awk; `cut -d: -f2` takes a column, `sed -n '10,40p'` a line range, " ..
		"and `grep -A/-B/-C` gives context",
	-- Named with the redirect for the same reason curl and wget were, back when
	-- they were only on this list: an archive is reached for as the way to get a
	-- library in, and there is a direct one. Deflate is not written here — a
	-- DataModel holds Instances, not files, so an unpacked archive would still
	-- have nowhere to land except the scripts inside it, which is what clone
	-- fetches on its own.
	unzip = "no archives here; `git clone <owner>/<repo> [dest]` reads a repository's " ..
		"scripts straight into the place, which is what a release zip was going to be for",
	tar = "no archives here; see `unzip`",
	xargs = "no xargs; `for f in $(grep -rl Foo); do ... $f; done` runs a command " ..
		"per item, and a filter can be piped straight into grep/head/tail/wc/sort/uniq/cut/sed/tr",
	-- A loop is claimed as a whole pipeline stage, so `for` never reaches here as
	-- a command. `do` and `done` still can, stranded by a loop with no `for`, and
	-- "unknown command" would print the entire command list beside each.
	["do"] = "only appears inside a loop — `for f in *.luau; do head -5 $f; done`",
	["done"] = "only appears inside a loop — `for f in *.luau; do head -5 $f; done`",
	["while"] = "no `while`: nothing here changes between two iterations, so it " ..
		"would run zero times or forever. `for f in <words>; do ... ; done` is the loop",
	["until"] = "no `until`; see `while`",
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

-- Ran fine, found nothing. In bash that is exit 1 and an ERROR is exit 2, and
-- keeping them apart is load-bearing in both directions at once: `grep X f ||
-- echo miss` has to see a false status, and `grep X f | wc -l` has to still run
-- wc. One flag could only ever give one of those, and it gave neither — a miss
-- set nothing at all, so `||` never fired after a grep that found nothing while
-- `grep -q` was the only spelling that worked.
--
-- So `failed` now means only "this errored, its output is a message", which is
-- what stops a pipeline; `unmatched` means "the answer was no", which only
-- `&&` and `||` read.
local unmatched = false
-- Set alongside it when the returned string is PROSE about the miss rather than
-- the answer itself — "no matches", and the `grep -i` nudge beside it.
--
-- Real grep prints nothing at all on a miss and says so through the exit status.
-- There is no exit status here and no stderr, so the prose is the only way a
-- person reading /sh learns anything happened — but a pipe is not a person, and
-- `grep foo . | wc -l` answering 1 is the worst failure in this file: a wrong
-- number, produced by the message that was supposed to be helpful, with nothing
-- in the output to say so. `grep foo . | grep bar` was searching the words "no
-- matches".
--
-- So: prose for the last stage, nothing for the ones feeding another command.
-- runPipeline is where that split is made, because only it knows which stage is
-- which. NOT every miss is prose — `grep -c` returning "0" found nothing AND is
-- the number that was asked for, so it sets `unmatched` directly and never
-- comes through here.
local missText = false
local function miss(message: string): string
	unmatched = true
	missText = message ~= ""
	return message
end

-- Prose WITHOUT the false status. The two are separable and have to be: `ls` on
-- an empty container SUCCEEDED — bash exits 0 and prints nothing — so
-- `ls empty && echo ok` must run the echo, while the sentence explaining the
-- emptiness must still not reach `wc -l` as if it were a row.
--
-- Folding this into miss() was a real regression, caught by asking what `&&`
-- does after it: every empty directory would have read as a failed command.
local function prose(message: string): string
	missText = message ~= ""
	return message
end

-- A note ABOUT the output rather than a line of it: "… 12 more matches", "… 30
-- empty services not shown". Same problem as miss prose and the same answer —
-- it is stderr with nowhere to go, so it rides on stdout for the last stage of
-- a pipeline and is dropped for the rest. Appended by runPipeline, once, rather
-- than by each handler, so there is one place that knows the rule.
local trailer: string? = nil
local function note(text: string)
	trailer = text
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
	command = {
		bool = "vV",
		-- Refused here rather than in the handler so the reason arrives before the
		-- lookup runs, and so the handler only ever reads letters it acts on.
		why = { ["-p"] = "runs with the default PATH, and there is no PATH here — " ..
			"every command is a builtin" },
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
	curl = {
		bool = "sSLkfiIGO", value = "XHdmebrow",
		long = { ["--silent"] = "bool:-s", ["--location"] = "bool:-L", ["--fail"] = "bool:-f",
			["--insecure"] = "bool:-k", ["--head"] = "bool:-I", ["--include"] = "bool:-i",
			["--request"] = "value:-X", ["--header"] = "value:-H", ["--data"] = "value:-d",
			["--data-raw"] = "value:-d", ["--data-binary"] = "value:-d",
			["--max-time"] = "value:-m", ["--get"] = "bool:-G", ["--referer"] = "value:-e",
			["--cookie"] = "value:-b", ["--range"] = "value:-r",
			["--output"] = "value:-o", ["--remote-name"] = "bool:-O",
			["--write-out"] = "value:-w",
			-- No short form: --json postdates single letters, and the other three
			-- never had one.
			["--json"] = "value", ["--compressed"] = "bool",
			["--data-urlencode"] = "value", ["--oauth2-bearer"] = "value" },
		-- -s -S -L -k -f --compressed are accepted and do nothing, which is not
		-- the same as ignoring an unknown flag: each one asks for behaviour that
		-- is already the case here. There is no progress meter to silence,
		-- RequestAsync follows redirects itself, certificates are not ours to
		-- skip, a non-2xx already fails, and asking for a gzipped response only
		-- to decompress it wins nothing when the engine handles the transfer.
		-- Refusing them would cost a corrected turn to arrive back at an
		-- identical request.
		--
		-- What is left out is what RequestAsync has no field for. It takes a URL,
		-- a method, headers, a body, a compression mode and a timeout, so every
		-- flag below is asking for a knob that does not exist rather than one
		-- nobody got round to wiring up.
		why = {
			["-u"] = "sends HTTP basic auth, which is a base64 this shell cannot " ..
				"compute — `--oauth2-bearer` covers a token, and -H takes the " ..
				"`Authorization: Basic …` header ready-made",
			["-A"] = "sets User-Agent, which RequestAsync will not send: Roblox " ..
				"locks that header along with Roblox-Id, and Content-Length is " ..
				"derived from the body",
			["--user-agent"] = "sets User-Agent, which Roblox locks; see -A",
			["--connect-timeout"] = "bounds the connect phase alone, and " ..
				"RequestAsync has one timeout for the whole request — that is -m",
			["-v"] = "traces the exchange on stderr, and there is no stderr here: " ..
				"it would land in the same pipe as the body. -i prints the " ..
				"response headers, -I prints them alone",
			["-x"] = "routes through a proxy, and RequestAsync has no field for " ..
				"one; the engine picks the route",
			["-T"] = "uploads a file with PUT — `-X PUT -d @path` reads a script " ..
				"and sends it",
			["-F"] = "sends a multipart form, and there is no file to attach: " ..
				"build the body with -d, or -d @path from a script",
			["-c"] = "saves cookies to a jar between runs, and each command here " ..
				"is its own request — -b sends a Cookie header",
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
	-- Subcommands arrive as OPERANDS, so `status` and `config` need nothing
	-- declared. -b/-i/-w reach diffKey and -U reaches unified, the same four
	-- `diff` itself honours, because the same two functions render both.
	--
	-- --branch has no short form here, and that is deliberate rather than an
	-- omission: git spells it -b, and -b is already --ignore-space-change above.
	-- Moving it would leave `git diff -b` parsing as a flag that wants a value.
	git = {
		bool = "biwAf", value = "Umn",
		long = { ["--unified"] = "value:-U", ["--ignore-case"] = "bool:-i",
			["--ignore-all-space"] = "bool:-w", ["--ignore-space-change"] = "bool:-b",
			["--all"] = "bool:-A", ["--message"] = "value:-m", ["--force"] = "bool:-f",
			["--branch"] = "value", ["--staged"] = "bool", ["--cached"] = "bool" },
	},
	-- No flags, which is a real answer: bash's three all ask for prose this help
	-- does not carry, so each is refused by name rather than silently accepted
	-- and ignored — the `rm -rf` failure this table exists to prevent.
	help = {
		why = {
			["-s"] = "prints the usage line alone, which is already all this prints",
			["-d"] = "prints a one-line description, and there are none here — the " ..
				"flag list is the documentation",
			["-m"] = "prints in man-page format, and there are no man pages",
		},
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
	-- -f is a printf format string, and there is no printf here to honour one.
	-- Named rather than silently dropped, because the thing it is usually reached
	-- for is zero-padding, which -w does.
	seq = {
		bool = "w", value = "s",
		long = { ["--separator"] = "value:-s", ["--equal-width"] = "bool:-w" },
		why = { ["-f"] = "is a printf format and there is no printf here; -w " ..
			"zero-pads to equal width, which is what -f is usually asked for" },
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
	cut = {
		bool = "s", value = "dfcb",
		long = { ["--delimiter"] = "value:-d", ["--fields"] = "value:-f",
			["--characters"] = "value:-c", ["--bytes"] = "value:-b",
			["--only-delimited"] = "bool:-s", ["--output-delimiter"] = "value" },
		-- -n and --complement are NOT declared. GNU accepts -n and ignores it,
		-- but a letter declared and never read is the `rm -rf` bug in miniature,
		-- and the rule here is that an unimplemented flag says so.
		why = {
			["-z"] = NO_NUL,
			["-n"] = "keeps a multibyte character whole, and .Source is a byte " ..
				"string — -b and -c are the same thing here, so there is nothing to split",
		},
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
	wget = {
		bool = "qS", value = "OT",
		long = { ["--quiet"] = "bool:-q", ["--server-response"] = "bool:-S",
			["--output-document"] = "value:-O", ["--timeout"] = "value:-T",
			["--header"] = "value", ["--post-data"] = "value",
			["--post-file"] = "value", ["--method"] = "value", ["--spider"] = "bool" },
		-- The refusals here are wget's identity rather than its edges: recursion
		-- and mirroring are the reason to reach for wget over curl, and they are
		-- the one thing a DataModel cannot be the target of.
		why = {
			["-r"] = "downloads recursively by following links, and there is no " ..
				"tree here to mirror into — fetch the pages you want by name",
			["--recursive"] = "follows links to build a local copy; see -r",
			["-m"] = "is -r with timestamps and infinite depth; see -r",
			["-p"] = "fetches the images and stylesheets a page needs, which is " ..
				"-r under another name; see -r",
			["-N"] = "re-downloads only when the remote is newer, and the times " ..
				"this shell keeps are its own observations of edits made here, " ..
				"with nothing to compare against a server's",
			["-c"] = "resumes a partial download, and RequestAsync returns a " ..
				"whole response or fails — there is no partial file to continue",
			["-t"] = "retries a failed download, and re-running the command is " ..
				"the retry; nothing here is holding state between the two",
			["-i"] = "reads a list of URLs from a file, and this shell has no " ..
				"loop to spend them on — one URL per command",
			["-P"] = "sets a directory to save under, which is the leading part " ..
				"of the path -O already takes whole",
			["-o"] = "redirects wget's own log to a file, and the log is the " ..
				"return value here; -q silences it and `> path` captures it",
		},
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

-- Forward-declared for `find -exec`, which runs a command per result and so has
-- to reach the dispatcher that is defined below every handler. The same shape
-- runLoopStage already has, and for the same reason: a handler that runs
-- commands sits above the thing that runs commands.
local runCommand: (any, { string }, string?) -> (string, boolean)

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

-- seq: the counted loop this shell could not otherwise write.
--
-- `for f in <words>` takes words, and there are no variables and no arithmetic to
-- make words out of a number, so the only counted loop available was typing the
-- numbers out. `$(...)` collapses whitespace to single spaces when it splices, so
-- `for i in $(seq 1 20); do mkdir Part$i; done` falls out with nothing else added.
--
-- The output is a stream rather than a listing, so it is CAPPED and REFUSED at
-- the cap rather than truncated: a listing cut short is still true as far as it
-- goes, where half a sequence is the wrong sequence and the loop built from it
-- silently does the wrong number of things.
--
-- ponytail: 1000, which is `cat`'s own line cap, for the same reason — it is the
-- point where output stops being a value and starts being a context bill.
local MAX_SEQ = 1000

-- How many decimals to print, taken from the operands as GNU does, so `seq 0 0.5
-- 2` reads 0.0 0.5 1.0 and `seq 1 5` stays 1 2 3 rather than 1.0 2.0 3.0.
local function decimalsOf(text: string): number
	local frac = text:match("^%-?%d*%.(%d+)$")
	return frac and #frac or 0
end

HANDLERS.seq = function(_, argv)
	local flags, values, operands = parse(argv)
	if #operands == 0 or #operands > 3 then
		return fail("seq", string.format("takes LAST, FIRST LAST, or FIRST STEP LAST " ..
			"— got %d operands", #operands))
	end
	-- One operand is the LAST, not the first: `seq 5` is 1..5.
	local firstText = if #operands == 1 then "1" else operands[1]
	local stepText = if #operands == 3 then operands[2] else "1"
	local lastText = operands[#operands]
	for _, text in ipairs({ firstText, stepText, lastText }) do
		if not tonumber(text) then
			return fail("seq", string.format("%q is not a number", text))
		end
	end
	local first = tonumber(firstText) :: number
	local step = tonumber(stepText) :: number
	local last = tonumber(lastText) :: number
	if step == 0 then
		return fail("seq", "a step of zero never reaches the end")
	end

	-- The epsilon is not decoration: (0.3 - 0) / 0.1 is 2.9999999999999996 in
	-- doubles, and flooring that drops the last value of `seq 0 0.1 0.3`.
	local count = math.floor((last - first) / step + 1e-9) + 1
	-- A step pointing away from the end is empty, not an error — `seq 5 1` prints
	-- nothing in every shell that has it.
	if count <= 0 then
		return ""
	end
	if count > MAX_SEQ then
		return fail("seq", string.format("%d values, and the cap is %d — a sequence " ..
			"cut short is the wrong sequence, so this refuses rather than truncating",
			count, MAX_SEQ))
	end

	local decimals = math.max(decimalsOf(firstText), decimalsOf(stepText), decimalsOf(lastText))
	local format = if decimals > 0 then "%." .. decimals .. "f" else "%d"
	local out: { string } = {}
	local width = 0
	-- first + index * step, never an accumulator: adding 0.1 to itself ten times
	-- does not arrive at 1.
	for index = 0, count - 1 do
		local text = string.format(format, first + index * step)
		out[index + 1] = text
		width = math.max(width, #text)
	end
	if flags["-w"] then
		for index, text in ipairs(out) do
			if #text < width then
				-- The zeros go after the sign, or -1 pads to 0-1.
				local sign, digits = text:match("^(%-?)(.*)$")
				out[index] = sign .. string.rep("0", width - #text) .. digits
			end
		end
	end
	return table.concat(out, valueOf(values, "-s") or "\n")
end

HANDLERS.cd = function(self, argv)
	local _, _, operands = parse(argv)
	local where = operands[1]
	if not where then
		-- bash goes home; there is no home here, and inventing one would mean
		-- picking a container and calling it that. Through fail() so the status is
		-- honest: this used to return the message as ordinary output, so `cd ||
		-- echo lost` never fired.
		return fail("cd", "requires a path — `cd /` is the root and `cd -` goes back")
	end
	-- `cd -` returns to wherever the last successful cd came from, and bash
	-- prints the new directory, which is what this returns anyway.
	if where == "-" then
		if not self.previous then
			return fail("cd", "nothing to go back to yet")
		end
		where = instancePath(self.previous)
	end
	local ok, err = self:cd(where)
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
	-- Computed ONCE per row, not inside the comparator. mtime is a table lookup
	-- and did not care, but Fs.size on a container is #GetDescendants() — a walk
	-- of the whole subtree — and table.sort calls its comparator O(n log n)
	-- times. `ls -S /Workspace` on a place with a few thousand parts was walking
	-- those parts thousands of times to order one listing, which made the flag
	-- that exists to find the big thing the slowest command in the shell.
	if rank then
		for _, row in ipairs(rows) do
			row.rank = rank(row)
		end
	end
	table.sort(rows, function(a, b)
		if rank and a.rank ~= b.rank then
			return a.rank < b.rank
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
	local sizeText = ""
	if isScript(inst) then
		-- Lines by default, because "how big is this file" is the question `ls -l`
		-- is asked about code. -h asks for human-readable BYTES specifically, so
		-- it switches the column rather than scaling a line count.
		sizeText = flags["-h"] and string.format("  %s", Fs.humanSize(Fs.size(inst)))
			or string.format("  %d lines", #splitLines(getSource(inst) or ""))
	else
		-- GetChildren, NOT Fs.size. Fs.size on a container is
		-- `#GetDescendants()`, and this branch only ever asked it "is that more
		-- than zero" before printing the CHILD count anyway — so every row of
		-- every `ls -l` was materialising the whole subtree under it to answer a
		-- question its own next line already had. `ls -la /` paid that once per
		-- service, Workspace included, which on a large place is the entire
		-- DataModel walked a hundred times over for a listing of a hundred lines.
		-- A container with descendants but no children cannot exist, so the two
		-- tests agree everywhere and only the cost differs.
		local children = #inst:GetChildren()
		if children > 0 then
			sizeText = string.format("  %d children", children)
		end
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
	-- The ROOT is exempt from the CAP. That cap is for a container holding
	-- thousands of parts; the service list is a different animal, the engine
	-- bounds it, and a service you cannot see is a whole subtree you cannot
	-- reach. Studio instantiates well over a hundred services, and rows are
	-- sorted before the cut, so `ls /` was dropping the alphabetical tail:
	-- Workspace, starting with W, fell off every single time while find, tree,
	-- stat and cat all still saw it. Deterministic, and invisible unless you
	-- counted.
	--
	-- The empty ones are collapsed instead, which is a different question — see
	-- hideEmpty below. A cut takes the tail whatever is in it; that one takes
	-- only rows with no subtree behind them, and says how many.
	local out: { string } = {}
	local atRoot = self:resolve(target) == game
	local budget = atRoot and math.huge or MAX_LIST
	local skipped = 0
	local firstDropped: string? = nil
	local emptyLabel: string? = nil

	-- Studio instantiates well over a hundred services whether the place uses
	-- them or not, and `ls /` is the first thing anything types. Almost all of
	-- them are empty: AdService, AnalyticsService, AvatarEditorService and ninety
	-- more, one line each, in the tool result of every session for the rest of
	-- that session. The ones with children are the place; the rest are furniture.
	--
	-- Collapsed rather than cut, and -a still lists them, which is what `-a`
	-- means everywhere else and what it did here before: nothing. Discovery
	-- survives either way — resolve reaches a service through game:GetChildren,
	-- not through this listing, so `ls /AdService` works whether or not it was
	-- printed.
	--
	-- Only the root, only without a glob, and only for containers with nothing
	-- in them. An empty Folder somewhere in a place is a real answer to `ls`.
	local hideEmpty = atRoot and not matcher and not flags["-a"] and not flags["-A"]
	local hidden = 0

	-- `ls -R /` re-resolves a path string for every container it descends into,
	-- so on a large place this walk is long enough to freeze Studio on its own.
	local breathe = Fs.breather()

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
			breathe()
			if hideEmpty and not header and #row.inst:GetChildren() == 0 then
				hidden += 1
			elseif budget <= 0 then
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
		-- Prose either way, so `ls empty | wc -l` answers 0 rather than 1 for the
		-- sentence saying it is empty — but the STATUS differs, and bash is where
		-- the difference comes from. An empty directory is a success (exit 0); a
		-- glob that matched nothing is an error (exit 2). Same sentence, and
		-- `ls empty && echo ok` has to run the echo.
		local text = string.format("(%s) %s", glob and "no matches" or "empty", emptyLabel)
		return if glob then miss(text) else prose(text)
	end
	-- Both of these say what was left out and how to see it, so an absence is
	-- never something the reader has to infer from a count that does not add up.
	-- Notes rather than rows, so `ls | wc -l` counts entries and not commentary.
	local notes: { string } = {}
	if skipped > 0 then
		notes[#notes + 1] = string.format("… %d more from %q on (narrow it: `ls %s/A*`, or `ls | grep <name>`)",
			skipped, firstDropped or "?", target or ".")
	end
	if hidden > 0 then
		notes[#notes + 1] = string.format(
			"… %d empty services not shown (`ls -a /` lists them; each is still reachable by name)",
			hidden)
	end
	if #notes > 0 then
		note(table.concat(notes, "\n"))
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

-- A glob for a command that takes exactly ONE path.
--
-- grep, du and tree each walk from a single root, so expanding a pattern and
-- taking the first match would answer for one file and say nothing about the
-- rest — a wrong answer wearing the shape of a right one. Several matches is a
-- refusal instead, naming the spelling that does work. One match expands
-- normally, so `grep foo Main*.luau` behaves.
--
-- Handlers that ITERATE their operands do not come through here: they call
-- expandGlobs and take everything it returns, which is what bash does.
local function oneGlobbed(self: any, cmd: string, path: string?,
	alternative: string): (string?, string?)
	if not path then
		return nil, nil
	end
	local matched = expandGlobs(self, { path })
	if #matched > 1 then
		return nil, fail(cmd, string.format("%q matches %d paths and %s takes one — %s",
			path, #matched, cmd, alternative))
	end
	return matched[1], nil
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
		local s, err, truncated = self:cat(operands[1])
		if not s then
			return fail("cat", err)
		end
		-- A note, not a line of the file: see runPipeline. Appended, the marker was
		-- counted by `cat big.luau | wc -l`; dropped, the truncation would vanish.
		if truncated then
			note(truncated)
		end
		return plain and s or catRender(s, flags)
	end
	-- Concatenated, with nothing between them, because that is what cat is named
	-- for. It used to print head's `==> path <==` banner over each file, which is
	-- wrong twice: no cat anywhere does it, and `cat a b > merged.luau` wrote the
	-- banners INTO the script. A model reading the output could not tell whether
	-- the header came from the file or from the shell.
	--
	-- The banner still exists where it belongs — `head -n 999999 a b` and `tail -n
	-- +1 a b` both print it, from joinFiles — so nothing that wanted it lost it.
	--
	-- NOTHING between them: cat concatenates bytes, so a file not ending in a
	-- newline really does join the next one's first line, and that is the answer.
	-- Anything else here is this shell inventing a file's contents.
	--
	-- An unreadable file says so inline and the rest still concatenate, which is
	-- cat's own behaviour minus the stream: cat sends that line to stderr and
	-- carries on. `fail()` is deliberately NOT called — it stops the pipeline, and
	-- `cat good.luau missing.luau | wc -l` has to still count the good one. The
	-- cost is that the message travels as data, the same seam as every other
	-- in-band status here; see FIDELITY.md §3.1. It gets its own newline because,
	-- unlike a file, it is not text anyone chose the ending of.
	local parts: { string } = {}
	local notes: { string } = {}
	for _, operand in ipairs(operands) do
		local s, err, truncated = self:cat(operand)
		if truncated then
			notes[#notes + 1] = truncated
		end
		if not s then
			parts[#parts + 1] = "cat: " .. tostring(err) .. "\n"
		elseif plain then
			parts[#parts + 1] = s
		else
			-- catRender works line-wise and drops the trailing newline, so one goes
			-- back on or the next file starts on the last line of this one.
			parts[#parts + 1] = catRender(s, flags) .. "\n"
		end
	end
	if #notes > 0 then
		note(table.concat(notes, "\n"))
	end
	return table.concat(parts)
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
	-- `stat *.luau` is a listing over every match, the same as ls.
	operands = expandGlobs(self, operands)
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
	local globErr
	target, globErr = oneGlobbed(self, "tree", target,
		"a tree is drawn from one root; `tree .` covers everything under the cwd")
	if globErr then
		return globErr
	end
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
	local only, globErr = oneGlobbed(self, "du", operands[1],
		"`du -a .` sizes everything below a container in one walk")
	if globErr then
		return globErr
	end
	local target, err = self:resolve(only)
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
	-- The only recursive walk here that did not breathe. find, grep, tree and
	-- `ls -R` all yield a frame when they have held the thread for one; du held
	-- it for the whole walk, and it is the walk with the largest allocation per
	-- node — `#GetDescendants()` builds a table holding a pointer to every
	-- instance in the subtree to return one integer. On a big place that is a
	-- multi-hundred-thousand-entry table per node with no frame in between for
	-- the collector to run in, which is the shape that runs Studio out of memory
	-- rather than merely making it slow.
	local breathe = Fs.breather()
	local function walk(inst: Instance, depth: number): number
		breathe()
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
	["-tag"] = true,
}

-- Named rather than skipped. Silently ignoring -maxdepth meant returning the
-- whole subtree to someone who asked for three levels, with nothing in the
-- output to say so, and the same is true of every filter below.
local FIND_UNSUPPORTED: { [string]: string } = {
	["-execdir"] = "runs the command from each result's own directory, and every " ..
		"command here takes a whole path — `-exec` is the same thing",
	["-ok"] = "prompts before running a command, and there is nothing to prompt — " ..
		"`-exec` is the same thing without the prompt",
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
	local exec: { command: { string }, batch: boolean }? = nil
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
			--
			-- `exact`, because that is what -name means: GNU matches the name
			-- against a glob, and a glob with no wildcard matches one string.
			-- Loose was the old behaviour and it over-reported — `-name Main` also
			-- returned `mainframe` and `Remainder`, extra hits indistinguishable
			-- from real ones. `find Handler`, the bare shorthand below, is still
			-- forgiving; that one is this harness's own and is meant to be.
			--
			-- -i is finally the difference between the two. They were the same
			-- function before, so one of the pair was a lie either way you read it.
			local matches = nameMatcher(value :: string,
				{ exact = true, caseSensitive = arg == "-name" })
			add(function(inst)
				return Fs.matchesName(inst, matches)
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
		elseif arg == "-tag" then
			-- CollectionService tags: a first-class DataModel concept that had no
			-- spelling anywhere in the shell, so the only way to find everything
			-- tagged Enemy was to already know where it was. Exact, not a glob:
			-- HasTag takes the string, and a tag nobody has added is not a typo
			-- worth guessing at.
			local wanted = value :: string
			add(function(inst)
				return Fs.hasTag(inst, wanted)
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
		elseif arg == "-exec" then
			-- Everything up to the terminator is the command. `\;` runs it once per
			-- result, `+` once with every result appended, exactly as find(1) has
			-- it — and the terminator arrives here as a plain word because a
			-- backslashed `;` is marked literal by the tokenizer.
			--
			-- This used to be refused, and the refusal's reason was wrong: it said
			-- there is no process to run. There is no process to run in this shell
			-- AT ALL — `cat`, `grep` and `sed` are Lua functions in HANDLERS, and
			-- the only thing anyone ever puts after -exec here is one of them. So
			-- there is nothing to fork and nothing missing: it is a dispatch per
			-- result, which is what runCommand already is.
			local command: { string } = {}
			i += 1
			local terminator: string? = nil
			while i <= #argv do
				if argv[i] == ";" or argv[i] == "+" then
					terminator = argv[i]
					break
				end
				command[#command + 1] = argv[i]
				i += 1
			end
			if not terminator then
				return fail("find", "-exec needs a terminating `\\;` (once per result) " ..
					"or `+` (once with all of them). The `;` has to be escaped or " ..
					"quoted, or it ends the command line instead.")
			end
			if #command == 0 then
				return fail("find", "-exec needs a command, as `-exec cat {} \\;`")
			end
			exec = { command = command, batch = terminator == "+" }
		elseif arg == "-print" then
			-- The default action, and printing is all this find does.
		elseif arg == "-delete" then
			deleting = true
		elseif FIND_UNSUPPORTED[arg] then
			return fail("find", arg .. " " .. FIND_UNSUPPORTED[arg])
		elseif arg:sub(1, 1) == "-" and #arg > 1 and not arg:match("^%-%d") then
			return fail("find", string.format("%s is not supported — find takes -name, " ..
				"-iname, -path, -regex, -type, -size, -empty, -perm, -inum, -tag, " ..
				"-newer, -mmin, -mtime, -maxdepth, -mindepth, -not, -o, -exec and " ..
				"-delete", arg))
		else
			bare[#bare + 1] = arg
		end
		i += 1
	end

	-- How many tests the expression itself carries. Counted BEFORE the bare
	-- operands are classified, because that count is what tells a path from a
	-- pattern below.
	local total = 0
	for _, group in ipairs(groups) do
		total += #group
	end

	-- `find / -type f` has no name at all, and `find Handler` has no path, so the
	-- bare operands cannot be classified by position alone.
	--
	-- A leading / or a bare . is unambiguously a root. The rest is decided by
	-- whether the expression has any tests: with one, every bare word is a PATH,
	-- which is GNU's rule and the shape the model writes; with none there is
	-- nothing else the word could be, so the first is the native `find <pattern>`
	-- and any after it are paths.
	--
	-- ROOTS, plural, because `find /A /B -name x` is how the search gets written
	-- the moment there is more than one place to look, and it is the exact shape
	-- that used to go wrong twice over: the second path was not searched at all,
	-- AND it was taken as the pattern, which then AND-ed itself into the last
	-- -o group and killed that clause too. The output was a short, plausible,
	-- silently incomplete list — the most expensive kind of wrong answer here,
	-- since the reader's next move is to conclude the instances do not exist.
	local pattern: string? = nil
	local roots: { string } = {}
	for _, arg in ipairs(bare) do
		if arg:sub(1, 1) == "/" or arg == "." or arg == ".." then
			roots[#roots + 1] = arg
		elseif total == 0 and not pattern then
			pattern = arg
		else
			roots[#roots + 1] = arg
		end
	end
	if pattern then
		local matches = nameMatcher(pattern)
		add(function(inst)
			return matches(inst.Name) or matches(displayName(inst))
		end)
		total += 1
	end

	-- A bare `find` would otherwise accept everything from the cwd, which at /
	-- means walking every descendant of the DataModel for nothing. A path is NOT
	-- enough to lift that, despite what the refusal used to say: `find /Workspace`
	-- with no test prints the whole subtree, which is `ls -R` with extra steps.
	if total == 0 and not minDepth and not maxDepth then
		return fail("find", "requires a pattern or a test — a path on its own lists " ..
			"the whole subtree, which is what `ls -R` is for")
	end

	local function test(inst: Instance): boolean
		-- No tests at all is `find /x -maxdepth 2`, which in GNU find lists the
		-- subtree down to that depth. The fold below returns false on an empty
		-- expression, so without this the depth bounds were the one thing you
		-- could pass find that made it report "no matches" for everything —
		-- `-maxdepth` on its own was dead, and dead in the direction that looks
		-- like an empty place rather than a broken flag.
		if total == 0 then
			return true
		end
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

	-- One walk per root, merged. Deduped by instance, because roots are allowed
	-- to overlap — `find / /Workspace` is legal and names some instances twice,
	-- and -delete below would then try to destroy the same one twice.
	local found: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	local skipped = 0
	-- "." is the cwd, which is what a find with no path at all searches.
	if #roots == 0 then
		roots = { "." }
	end
	for _, where in ipairs(roots) do
		local batch, err = self:find(where, test, { minDepth = minDepth, maxDepth = maxDepth })
		if not batch then
			return fail("find", err)
		end
		skipped += ((batch :: any).skipped or 0)
		for _, inst in ipairs(batch) do
			if not seen[inst] then
				seen[inst] = true
				-- Capped across the whole command, not per root: N roots must not
				-- buy N times the ceiling every other search is held to.
				if #found >= MAX_LIST then
					skipped += 1
				else
					found[#found + 1] = inst
				end
			end
		end
	end
	if #found == 0 then
		return miss("no matches")
	end

	if deleting then
		-- Deepest first, so removing a parent cannot invalidate a child still on
		-- the list. Destroy() takes the subtree with it.
		--
		-- Depths are measured once. instancePath walks to the root building a
		-- string, and calling it from inside the comparator did that twice per
		-- comparison — O(n log n) walks to order at most MAX_LIST entries. Real
		-- depth rather than path length, too: length was a proxy that a long name
		-- beside a deep path could invert, and the one thing this ordering has to
		-- guarantee is that a child is never left behind its destroyed parent.
		local depth: { [Instance]: number } = {}
		for _, inst in ipairs(found) do
			local levels, current = 0, inst.Parent
			while current do
				levels += 1
				current = current.Parent
			end
			depth[inst] = levels
		end
		table.sort(found, function(a, b)
			return depth[a] > depth[b]
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

	if exec then
		local paths: { string } = {}
		for _, inst in ipairs(found) do
			paths[#paths + 1] = instancePath(inst)
		end
		-- `{}` is replaced wherever it appears, which is what find(1) does; with no
		-- `{}` at all the command still runs per result, also as find(1) has it.
		-- Under `+` the paths go where the `{}` was, spliced as separate words, and
		-- onto the end when there is none.
		local function expand(into: { string }, replacements: { string }): { string }
			local out: { string } = {}
			local placed = false
			for _, word in ipairs(into) do
				if word == "{}" then
					placed = true
					for _, value in ipairs(replacements) do
						out[#out + 1] = value
					end
				else
					out[#out + 1] = word
				end
			end
			if not placed and (exec :: any).batch then
				for _, value in ipairs(replacements) do
					out[#out + 1] = value
				end
			end
			return out
		end

		-- Saved because runCommand RESETS these on entry and reads them again after
		-- this handler returns: without the restore, find's own status would be
		-- whatever the last thing it ran happened to leave behind.
		local outerTrailer = trailer
		local pieces: { string } = {}
		local runs: { { string } } = {}
		if exec.batch then
			runs[1] = expand(exec.command, paths)
		else
			for _, path in ipairs(paths) do
				runs[#runs + 1] = expand(exec.command, { path })
			end
		end
		for _, one in ipairs(runs) do
			local output, ok = runCommand(self, one, nil)
			if not ok and failed then
				-- Stopped at the first real failure, the way a pipeline is, and for
				-- the same reason: `failed` means the output IS the message, so
				-- letting it run on would mix an error into the results as data with
				-- nothing to tell them apart.
				trailer = outerTrailer
				return fail("find", output)
			end
			if output ~= "" then
				pieces[#pieces + 1] = output
			end
		end
		failed, unmatched, missText, trailer = false, false, false, outerTrailer
		if skipped > 0 then
			note(string.format("… %d more matches not run (narrow the path or the pattern)",
				skipped))
		end
		return table.concat(pieces, "\n")
	end

	local lines: { string } = {}
	for _, inst in ipairs(found) do
		lines[#lines + 1] = instancePath(inst) .. "  [" .. inst.ClassName .. "]"
	end
	if skipped > 0 then
		-- A note, not a result row: `find / -name '*.luau' | wc -l` counts files.
		note(string.format("… %d more matches (narrow the path or the pattern)", skipped))
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
		return Fs.matchesName(inst, matches)
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

-- test / [ : a predicate with no output, only a status.
--
-- Worth having for one reason: `&&` and `||` already exist, so `[ -f Main.luau ]
-- && cat Main.luau` needs no `if` and no change to the parser. One handler buys
-- most of what `if` is for, which is why it comes first.
--
-- A false test is a MISS and not a failure, the same line grep draws: nothing
-- went wrong, the answer was no. A malformed one IS a failure, which is bash's
-- 2-versus-1 and the reason `[ -f ]` cannot read as "no".
--
-- Parsed straight off argv rather than through the spec gate, for find's reason:
-- here the operators ARE the operands. `-eq` through partition is two bundled
-- booleans, -e and -q, and `-f Main.luau` would eat the path as a flag's value.
local TEST_OPS = "-e -f -d -s -z -n = != -eq -ne -lt -le -gt -ge, and ! to negate"

local TEST_REFUSED: { [string]: string } = {
	-- chmod here maps onto Disabled, Archivable and Locked, none of which is a
	-- permission to read or write, so there is nothing for these to answer.
	["-r"] = "there are no permissions on an Instance — `-e` asks whether it is " ..
		"there and `-f` whether it has source",
	["-w"] = "see -r",
	["-x"] = "see -r",
	["-L"] = "an Instance has exactly one Parent, so there is no link to follow",
	["-h"] = "see -L",
	-- POSIX deprecates both, and this shell already has the replacement.
	["-a"] = "is deprecated even in bash; `[ x ] && [ y ]` chains two tests",
	["-o"] = "is deprecated even in bash; `[ x ] || [ y ]` chains two tests",
}

local TEST_NUMERIC: { [string]: (number, number) -> boolean } = {
	["-eq"] = function(a, b) return a == b end,
	["-ne"] = function(a, b) return a ~= b end,
	["-lt"] = function(a, b) return a < b end,
	["-le"] = function(a, b) return a <= b end,
	["-gt"] = function(a, b) return a > b end,
	["-ge"] = function(a, b) return a >= b end,
}

HANDLERS.test = function(self, argv)
	local name = argv[1]
	local args: { string } = {}
	table.move(argv, 2, #argv, 1, args)
	-- `[` is the same command wearing brackets, and the closing one is REQUIRED:
	-- without the check, `[ -f x` would silently answer a question nobody
	-- finished asking.
	if name == "[" then
		if args[#args] ~= "]" then
			return fail("[", "missing the closing `]`")
		end
		args[#args] = nil
	end

	local negate = false
	while args[1] == "!" do
		negate = not negate
		table.remove(args, 1)
	end
	-- The only two exits that are not errors. Silence either way: a test that
	-- printed anything would land in the output of every guard using it.
	local function answer(value: boolean): string
		return if value ~= negate then "" else miss("")
	end

	if #args == 0 then
		-- bash: `test` alone is false, and `[ ! ]` is true. Not an error either
		-- way, which is why this is here and not with the refusals.
		return answer(false)
	end
	if #args == 1 then
		return answer(args[1] ~= "")
	end

	if #args == 2 then
		local op, operand = args[1], args[2]
		if op == "-z" then return answer(operand == "") end
		if op == "-n" then return answer(operand ~= "") end
		local why = TEST_REFUSED[op]
		if why then
			return fail(name, op .. " " .. why)
		end
		if op == "-e" or op == "-f" or op == "-d" or op == "-s" then
			local target = self:resolve(operand)
			if not target then
				-- A path that does not resolve is the answer "no", not an error.
				return answer(false)
			end
			if op == "-e" then return answer(true) end
			if op == "-f" then return answer(isScript(target)) end
			if op == "-d" then return answer(not isScript(target)) end
			-- -s is "has something in it", and what that means splits exactly where
			-- `find -type` splits it: a script's something is its source, a
			-- container's is its children.
			return answer(if isScript(target)
				then #(getSource(target) or "") > 0
				else #target:GetChildren() > 0)
		end
		return fail(name, string.format("unknown operator %q — %s", op, TEST_OPS))
	end

	if #args == 3 then
		local left, op, right = args[1], args[2], args[3]
		if op == "=" or op == "==" then return answer(left == right) end
		if op == "!=" then return answer(left ~= right) end
		local compare = TEST_NUMERIC[op]
		if compare then
			local a, b = tonumber(left), tonumber(right)
			if not a or not b then
				-- bash calls this an error rather than a false, and it is right to:
				-- `[ $x -eq 1 ]` on an empty x is a bug, not an answer.
				return fail(name, string.format("%s compares numbers, and %q is not one",
					op, if a then right else left))
			end
			return answer(compare(a, b))
		end
		local why = TEST_REFUSED[op]
		if why then
			return fail(name, op .. " " .. why)
		end
		return fail(name, string.format("unknown operator %q — %s", op, TEST_OPS))
	end

	return fail(name, string.format("takes 1 to 3 arguments, got %d — `[ x ] && [ y ]` " ..
		"is how two tests join", #args))
end

-- Same handler, and it reads argv[1] to know which spelling it was given.
HANDLERS["["] = HANDLERS.test

-- `command -v NAME` is the portable "does this exist", and the answer is shorter
-- here than in bash: with no PATH, a name either is a builtin or is nothing.
--
-- A miss prints NOTHING and reports a false status, which is the entire point of
-- the form — `command -v sed && sed ...` reads the status, not the text, and a
-- message here would land in the output of every guard that used it. `grep -q`
-- sets `unmatched` the same way for the same reason.
--
-- The bare `command NAME args` form never reaches here: runCommand strips the
-- prefix, so the command that runs is the real one, with its own spec.
HANDLERS.command = function(_, argv)
	local flags, _, operands = parse(argv)
	local name = operands[1]
	if not name or name == "" then
		-- No operand is a malformed invocation, not a lookup that missed. Silence
		-- is only the right answer for a name that was actually searched for, so
		-- these two cases must not share one.
		if flags["-v"] or flags["-V"] then
			return fail("command", "-v requires a name, as `command -v grep`")
		end
		return ""       -- bare `command` runs nothing, successfully, as in bash
	end
	-- The same three tables `which` reads, in the same order. Not shared with it
	-- as a helper: they are the source tables themselves, so there is nothing to
	-- drift, and the two commands word their answers differently on purpose.
	local what: string? = nil
	if HANDLERS[name] then
		what = "a shell builtin"
	elseif isSeparateTool(name) then
		what = "a separate tool, not a shell command"
	end
	if flags["-V"] then
		if not what then
			return fail("command", name .. ": not found")
		end
		return name .. " is " .. what
	end
	if flags["-v"] then
		if not what then
			unmatched = true
			return ""
		end
		-- bash prints the path for an external command and the bare name for a
		-- builtin. Everything here is a builtin, so it is always the name.
		return name
	end
	-- Only reachable when the word after `command` began with a dash, so the
	-- prefix strip left it alone and it is not a command name.
	return fail("command", string.format("%q is not a command name — `command -v NAME` " ..
		"asks whether one exists, `command NAME args` runs it", name))
end

-- `help` with no argument lists what exists; `help NAME` gives one command's
-- flags. Both are read out of HANDLERS and SPECS, so help cannot describe a
-- command that is not there, nor miss one that is.
--
-- Deliberately no per-command prose. bash's help carries a paragraph and an
-- Options block per builtin, and writing 33 of those is the tool description
-- that bash.lua kept OUT of the tool description, arriving through another door.
-- `ls`, `grep` and `cp` describe themselves; their flags are the part that
-- cannot be guessed, and that part is already written down.
HANDLERS.help = function(_, argv)
	local _, _, operands = parse(argv)

	local function describe(name: string): string
		local spec = SPECS[name]
		-- A command absent from SPECS is unchecked rather than flagless, so the
		-- honest answer for it is to say nothing about flags at all.
		if not spec then
			return name .. ": shell builtin"
		end
		-- The flags it TAKES, and nothing about the ones it refuses. Those reasons
		-- live in spec.why and already arrive on their own, at the one call that
		-- reached for the flag. Listing them here turned that pull into a push:
		-- `help ls` came out as eight refusals over 1027 characters and `help curl`
		-- as ten over 1388, most of it naming DataModel internals to answer a
		-- question nobody had asked. Nothing needs to know what this is running on
		-- to use the shell, and this was the one place that insisted.
		return name .. ": shell builtin\n  flags: " .. flagNames(spec)
	end

	local topic = operands[1]
	if not topic or topic == "" then
		return "shell builtins — `help NAME` for one command's flags:\n  " ..
			table.concat(Shell.COMMANDS, " ")
	end
	if HANDLERS[topic] then
		return describe(topic)
	end
	-- A name that names something real gets its own reason. "no help topics
	-- match" would be true and useless for both of these.
	if isSeparateTool(topic) then
		return fail("help", topic .. ": separate tool, not a shell command")
	end
	local why = UNSUPPORTED[topic]
	if why then
		return fail("help", topic .. ": " .. why)
	end
	-- bash's help takes a pattern, so `help gr*` works. nameMatcher is the one
	-- --include and which already use, which also makes a bare substring match:
	-- `help ec` finds echo.
	local matches = nameMatcher(topic)
	local found: { string } = {}
	for _, name in ipairs(Shell.COMMANDS) do
		if matches(name) then
			found[#found + 1] = name
		end
	end
	if #found == 0 then
		return fail("help", string.format("no help topics match %q — `help` lists them", topic))
	end
	if #found == 1 then
		return describe(found[1])
	end
	-- bash prints every match in full. Names only here, for the reason MAX_RESULTS
	-- exists: `help *` in full is 35 entries of output nobody asked for, and the
	-- next call names the one that was wanted.
	return table.concat(found, " ")
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
	local path, globErr = oneGlobbed(self, "grep", operands[firstOperand],
		"`grep -r --include='*.luau' PATTERN .` filters a walk, which is what a " ..
		"pattern over files means here")
	if globErr then
		return globErr
	end

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
		local streamOk, hits, taken, refused = pcall(Fs.grepLines, splitLines(stdin), programs, opts)
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
				unmatched = true
			end
			return ""
		end
		if flags["-c"] then
			-- Matching LINES, capped by -m alone, the same number the walked path
			-- now reports. Counting the hits instead counted -o's one-row-per-match
			-- expansion, so `-co` disagreed with `-c`.
			return tostring(math.min(taken + refused, opts.limit or math.huge))
		end
		-- Line numbers of a stream are the stream's, not a file's, so they are
		-- only worth printing when asked for.
		return #hits > 0
			and formatHits(hits, false, flags["-n"] == true, before + after > 0)
			or miss("no matches")
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
			unmatched = true
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
			-- isScript, NOT getSource. The only question here is "is this a file",
			-- and getSource answers it by handing back a COPY of the whole script:
			-- this re-walk was reading every source in the place a second time for
			-- a boolean that getSource's own first line already had. The two agree
			-- exactly — getSource returns nil for everything isScript rejects — so
			-- this is the same answer without the second read of the whole place.
			if isScript(inst) then
				-- Built once. It was called twice per instance, once to look up and
				-- once to emit, which is two whole paths walked to game per script.
				local instPath = instancePath(inst)
				if not withMatch[instPath] then
					out[#out + 1] = instPath
				end
			end
		end
		return table.concat(out, "\n")
	end

	if #hits == 0 then
		if flags["-c"] then
			-- Found nothing AND the number that was asked for, so `unmatched` is set
			-- by hand rather than through miss(): a miss's text is suppressed when
			-- something is downstream, and `grep -c X . | sort -n` must still get
			-- its zero. The one place where "nothing found" is legitimately data.
			unmatched = true
			return "0"
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
				return miss(string.format("no matches — %d with `grep -i` (grep is case-sensitive)",
					#found))
			end
		end
		return miss("no matches")
	end

	if flags["-c"] then
		-- Off the per-file counts, not off `matches`: the hit list has already
		-- been truncated by MAX_RESULTS, so counting it answered "how many fit"
		-- on the one command whose entire output is a number.
		local counts: { { path: string, n: number } } = (hits :: any).counts or {}
		-- grep prefixes the path when it was handed more than one input, so a
		-- named script counts bare and a subtree counts per file — which is what
		-- `grep -rc X dir | grep -v ":0"` is written against. -h forces the bare
		-- total, -H forces the prefix, as everywhere else.
		local target = self:resolve(path)
		local perFile = not flags["-h"] and (flags["-H"] == true or not (target and getSource(target)))
		if not perFile then
			local total = 0
			for _, entry in ipairs(counts) do
				total += entry.n
			end
			return tostring(total)
		end
		-- Files with no match are left out rather than printed as `path:0`, which
		-- is ripgrep's default and the only survivable one here: a place with a
		-- few thousand scripts would spend the whole reply on zeros.
		local out: { string } = {}
		for _, entry in ipairs(counts) do
			out[#out + 1] = string.format("%s:%d", entry.path, entry.n)
		end
		return table.concat(out, "\n")
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
		-- A note, not a match: `grep -rn X . | wc -l` used to answer 101 for a
		-- hundred hits, because the line saying so was counted as one of them.
		note(string.format("… %d more matches (narrow the path or the pattern)", skipped))
	end
	return body
end

-- The part of a line sort actually compares. -k picks a field, -t says what
-- separates them, -b drops leading blanks, -f folds case. Written once because
-- sort and uniq both need "the comparable part of this line" and their two
-- answers drifting would make `sort | uniq` disagree with itself.
-- The number `sort -n` compares: leading blanks, an optional sign, digits, and
-- it stops at the first thing that is not one. Anything with no number in front
-- is zero, which is how GNU orders a line of prose against a line of counts.
local function numericPrefix(text: string): number
	return tonumber(text:match("^%s*[-+]?%d*%.?%d+") or "") or 0
end

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
			-- than erroring — and the value is read off the LEADING number, not
			-- the whole line. Lua's tonumber demands the entire string be a
			-- number, so "12 /Workspace/Thing" measured as 0 and fell through to
			-- the lexical tiebreak below. That shape is not an edge case here: it
			-- is exactly what du, wc and `grep -c` print, which is most of what
			-- anyone pipes into `sort -n`.
			--
			-- No exponent, deliberately: GNU reads 1e3 as 1 under -n and wants -g
			-- for the other reading.
			local na, nb = numericPrefix(ka), numericPrefix(kb)
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
	-- `touch *.luau` restamps what is already there. A pattern that matches
	-- nothing passes through as bash leaves it, and touch then creates a script
	-- under that literal name — which is bash's behaviour too, and the reason
	-- nullglob exists there.
	operands = expandGlobs(self, operands)
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
	-- From the second: the first operand is the MODE, and `chmod +x *.luau` would
	-- otherwise try to match `+x` against the children of the cwd.
	if mode then
		local targets = expandGlobs(self, table.move(operands, 2, #operands, 1, {}))
		operands = { mode }
		table.move(targets, 1, #targets, 2, operands)
	end
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
		local _, applyErr = withUndo("agent: chmod " .. mode, function()
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

	local link, linkErr = withUndo("agent: ln " .. leaf, function()
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

-- One file's worth of sed. Split out because sed takes SEVERAL file operands and
-- the handler used to read only operands[1]: `sed -i 's/a/b/' f1 f2 f3` rewrote
-- f1, said nothing about f2 or f3, and returned a success message — a partial
-- answer shaped exactly like a complete one, on the one command that writes.
--
-- Range state (`active`) is per file, which is why it is built here rather than
-- threaded in: a `/start/,/end/` range left open at the end of one file must not
-- select the beginning of the next.
--
-- Returns nil plus a message on failure. The third value is `q`, which quits sed
-- entirely rather than just the file it fired in.
local function applySed(commands: { SedCommand }, lines: { string }, quiet: boolean):
	(string?, string?, boolean)
	local quitAll = false
	local out: { string } = {}
	local active: { [number]: boolean } = {}

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
					return nil, Regex.isBudget(res)
						and "that pattern is too expensive to run — anchor it, or replace a " ..
							"nested quantifier like (a+)+ with a single one"
						or tostring(res)
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
					return nil, "y/// needs both sets to be the same length"
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
			quitAll = true
			break
		end
	end
	return table.concat(out, "\n"), nil, quitAll
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

	-- Globbed, and only from firstFile: operand one is the SCRIPT, and `sed -i
	-- 's/a/b/' *.luau` is the single most common thing anyone asks sed to do.
	-- Expanding the script too would try to match `s/a/b/` against the cwd.
	local files: { string } = {}
	for index = firstFile, #operands do
		files[#files + 1] = operands[index]
	end
	files = expandGlobs(self, files)

	-- Both refusals BEFORE anything is read, so a bad flag combination cannot
	-- rewrite the first file and only then stop.
	if flags["-i"] and #files == 0 then
		return fail("sed", "-i edits a file in place, so it needs a file operand")
	end
	-- Real sed would happily truncate a file to a printed range. That is a
	-- destructive reading of a flag combination whose whole purpose is to read,
	-- so it is refused rather than performed.
	if flags["-i"] and flags["-n"] then
		return fail("sed", "-i -n would overwrite the file with only the printed lines; " ..
			"drop one of them")
	end

	local sources, inputErr = inputs(self, files, stdin)
	if not sources then
		return fail("sed", inputErr)
	end

	local quiet = flags["-n"] == true
	local parts: { { path: string?, body: string } } = {}
	for _, source in ipairs(sources) do
		local result, applyErr, quit = applySed(commands, splitLines(source.text), quiet)
		if not result then
			return fail("sed", applyErr)
		end
		if flags["-i"] then
			-- Through :write, so the substitution lands in one undo record like every
			-- other mutation rather than being the one edit Ctrl+Z cannot reach.
			local wrote, writeErr = self:write(source.path, result .. "\n")
			if not wrote then
				-- Named, because with several files the caller cannot tell which one
				-- stopped it from the message alone.
				return fail("sed", tostring(source.path) .. ": " .. tostring(writeErr))
			end
			parts[#parts + 1] = { path = source.path, body = wrote }
		else
			parts[#parts + 1] = { path = source.path, body = result }
		end
		if quit then
			break
		end
	end
	-- -i already names every file it wrote, so a header would say it twice.
	return joinFiles(parts, nil, flags["-i"])
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

-- cut: the field-splitting that had no spelling here at all.
--
-- The gap it fills is narrow and real. `awk` is refused, and its stand-in was
-- "use sed -n for a line range" — which answers a different question: a range
-- picks ROWS, and every `awk '{print $2}'` anyone writes wants a COLUMN. There
-- was no way to take the second field of anything, so a model reaching for one
-- had to fall back to `run`, which executes arbitrary Luau to do what a filter
-- does.
--
-- LIST syntax is cut's own: `1`, `1,3`, `2-`, `-3`, `2-4`, in any combination,
-- and the output is always in FILE order with duplicates collapsed, never in the
-- order written. `cut -f3,1` printing field 1 then 3 is not a quirk to preserve
-- compatibility with; it is what cut does, and a model that expected reordering
-- gets the same answer it would get anywhere else.
local function parseList(spec: string): ({ { number } }?, string?)
	if spec == "" then
		return nil, "needs a list, as `-f1`, `-f2,4` or `-f2-`"
	end
	local ranges: { { number } } = {}
	for part in spec:gmatch("[^,]+") do
		local lo, hi = part:match("^(%d*)%-(%d*)$")
		if lo then
			-- `-3` is 1..3 and `2-` is 2..end; `-` alone is every field, which cut
			-- rejects as ambiguous and so does this.
			if lo == "" and hi == "" then
				return nil, string.format("%q is not a range — write `-3`, `2-` or `2-4`", part)
			end
			ranges[#ranges + 1] = { tonumber(lo) or 1, tonumber(hi) or math.huge }
		else
			local single = tonumber(part)
			if not single or single < 1 or single % 1 ~= 0 then
				return nil, string.format("%q is not a field number — they start at 1", part)
			end
			ranges[#ranges + 1] = { single, single }
		end
	end
	return ranges, nil
end

local function inList(ranges: { { number } }, index: number): boolean
	for _, range in ipairs(ranges) do
		if index >= range[1] and index <= range[2] then
			return true
		end
	end
	return false
end

HANDLERS.cut = function(self, argv, stdin)
	local flags, values, operands = parse(argv)
	-- Exactly one of -f/-c/-b, as cut requires. Defaulting to one of them would
	-- make `cut 2 f.luau` silently pick an interpretation nobody asked for.
	local mode: string? = nil
	for _, letter in ipairs({ "-f", "-c", "-b" }) do
		if values[letter] then
			if mode then
				return fail("cut", "only one of -f, -c or -b at a time")
			end
			mode = letter
		end
	end
	if not mode then
		return fail("cut", "needs -f (fields), -c (characters) or -b (bytes), " ..
			"as `cut -d: -f2` or `cut -c1-40`")
	end
	local ranges, listErr = parseList(valueOf(values, mode) :: string)
	if not ranges then
		return fail("cut", listErr)
	end

	-- TAB, which is cut's default and the one worth stating: a model writing
	-- `cut -f2` over space-separated text gets the whole line back and no error,
	-- exactly as it would anywhere else. -d is how you say otherwise.
	local delimiter = valueOf(values, "-d") or "\t"
	if mode == "-f" and #delimiter ~= 1 then
		return fail("cut", "-d takes a single character")
	end
	-- -s drops lines with no delimiter at all; without it cut passes them
	-- through whole, which is its documented behaviour and surprises people.
	local skipUndelimited = flags["-s"] == true
	local outputDelimiter = valueOf(values, "--output-delimiter") or delimiter

	local files, inputErr = inputs(self, expandGlobs(self, operands), stdin)
	if not files then
		return fail("cut", inputErr)
	end

	local parts: { { path: string?, body: string } } = {}
	for _, file in ipairs(files) do
		local out: { string } = {}
		for _, line in ipairs(splitLines(file.text)) do
			if mode ~= "-f" then
				-- -c and -b are the same thing here: .Source is a byte string and
				-- there is no multibyte-aware column to be had, so claiming they
				-- differ would be inventing a distinction.
				local picked: { string } = {}
				for index = 1, #line do
					if inList(ranges, index) then
						picked[#picked + 1] = line:sub(index, index)
					end
				end
				out[#out + 1] = table.concat(picked)
			elseif not line:find(delimiter, 1, true) then
				if not skipUndelimited then
					out[#out + 1] = line
				end
			else
				local fields: { string } = {}
				-- A plain split, so an empty field between two delimiters is a real
				-- field. This is where cut and awk part company and it is the whole
				-- reason `cut -d:` works on `a::b`.
				local from = 1
				while true do
					local at = line:find(delimiter, from, true)
					if not at then
						fields[#fields + 1] = line:sub(from)
						break
					end
					fields[#fields + 1] = line:sub(from, at - 1)
					from = at + 1
				end
				local picked: { string } = {}
				for index, field in ipairs(fields) do
					if inList(ranges, index) then
						picked[#picked + 1] = field
					end
				end
				out[#out + 1] = table.concat(picked, outputDelimiter)
			end
		end
		parts[#parts + 1] = { path = file.path, body = table.concat(out, "\n") }
	end
	-- No `==> path <==` banner: cut is a filter, and coreutils prints none.
	local rendered: { string } = {}
	for _, part in ipairs(parts) do
		rendered[#rendered + 1] = part.body
	end
	return table.concat(rendered, "\n")
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

-- curl and wget: the two commands here that are not about the DataModel.
--
-- They earn the exception by feeding everything that is. A fetched body lands in
-- the same pipeline as any other output, so `curl URL | grep -n foo`, `| sed -n
-- '1,80p'` and `> /ServerStorage/tmp/doc.luau` all work with no second tool, and
-- wget writes a script directly. What that replaces was four calls — mkdir, write
-- a probe, run it, read it back — to reach a 500-character cap on the run tool's
-- returned value, with its 10-second yield budget over an HTTP request.
--
-- The two split on one line: curl prints, wget saves. Everything either of them
-- knows about HTTP lives in the helpers below, so the split really is that line
-- and not two implementations that agree today.
--
-- RequestAsync rather than GetAsync: GetAsync throws on a non-2xx and hands back
-- no status, and "the server said 404" arriving as a Lua error string is the
-- shape that gets misread as "the network is broken".
local HttpService = game:GetService("HttpService")

-- Every verb RequestAsync documents. Checked here rather than passed through,
-- because the engine answers a misspelled one with a generic failure that reads
-- like the server refused the request. The set is derived from the list so the
-- check and the message it prints cannot disagree.
local HTTP_METHODS = { "GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "TRACE", "PATCH" }
local METHOD_SET: { [string]: boolean } = {}
for _, verb in ipairs(HTTP_METHODS) do
	METHOD_SET[verb] = true
end

-- Flags that are one request header and nothing else. curl gives each its own
-- letter; here they are a table, because four near-identical branches is how one
-- of them ends up reading the wrong value.
local HEADER_FLAGS: { [string]: { header: string, prefix: string? } } = {
	["-e"] = { header = "referer" },
	["-b"] = { header = "cookie" },
	["-r"] = { header = "range", prefix = "bytes=" },
	["--oauth2-bearer"] = { header = "authorization", prefix = "Bearer " },
}

-- Headers RequestAsync will not let a caller set, and why. Named on the way in:
-- sending one otherwise fails the whole request with nothing to say which header
-- was the problem. Above parseHeaders because that is what reads it: a local
-- declared below a function that names it is not an upvalue, it is a nil global.
local LOCKED_HEADERS: { [string]: string } = {
	["content-length"] = "is derived from the body",
	["user-agent"] = "is locked by Roblox",
	["roblox-id"] = "is locked by Roblox",
}

-- `Name: value`, the spelling curl's -H and wget's --header share.
--
-- Keys are lowercased. Header names are case-insensitive, HTTP/2 requires the
-- wire form to be lowercase anyway, and it means a default can be written as
-- `if not headers["content-type"]` rather than a scan for whichever casing the
-- caller happened to use. Getting that wrong sends two Content-Types and leaves
-- the server to pick.
local function parseHeaders(raw: { string }?): ({ [string]: string }?, string?)
	local headers: { [string]: string } = {}
	for _, header in ipairs(raw or {}) do
		local name, value = header:match("^%s*([^:]+):%s*(.*)$")
		if not name then
			return nil, string.format("bad header %q — expected `Name: value`", header)
		end
		local lower = name:lower()
		local locked = LOCKED_HEADERS[lower]
		if locked then
			return nil, string.format(
				"%s %s, and RequestAsync refuses a request that sets it", name, locked)
		end
		headers[lower] = value
	end
	return headers, nil
end

-- A body read out of a script: curl's `-d @path` and wget's `--post-file`. The
-- counterpart of `> path`, so a payload is written once with the editor and
-- resent rather than retyped into every call.
local function bodyFromScript(self: any, path: string): (string?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	if not isScript(target) then
		return nil, "not a script: " .. instancePath(target)
	end
	return getSource(target) or "", nil
end

-- RequestAsync's own default is undocumented and reported at a minute or more.
-- A request that hangs that long holds the turn it was called from, which is the
-- same objection that rules out `tail -f`, so this shell sets its own and lets
-- -m move it. curl has no default max-time; this is a deliberate departure.
--
-- ponytail: the engine refuses a Timeout ABOVE its own default, so this number
-- only works while it stays under that. Every report puts the default at 60s or
-- more. If it is ever lowered past this, the failure is loud and immediate and
-- names Timeout, rather than silent.
local CURL_TIMEOUT = 30

-- Where -G puts the data. Its own function because the branch is silent when it
-- is wrong: a second `?` in a URL is not an error anyone reports, the server just
-- reads a parameter nobody sent.
local function appendQuery(url: string, query: string): string
	return url .. (url:find("?", 1, true) and "&" or "?") .. query
end

-- What wget saves under when -O does not say. wget takes the last path segment
-- and falls back to index.html; the query string is dropped, because parameters
-- are not a name. Its own function for the same reason as appendQuery: a wrong
-- answer here writes a real script into someone's place under a name nobody
-- asked for. nil means there was nothing to take, and wget refuses rather than
-- inventing index.html.
local function nameFromUrl(url: string): string?
	local path = url:match("^https?://[^/?#]*([^?#]*)") or ""
	return path:match("([^/]+)$")
end

-- HttpService refuses every Roblox domain outright. Worth naming here rather
-- than letting the engine's own wording come back, because the docs an agent is
-- most likely to reach for live on create.roblox.com, and a refusal that reads
-- like a network failure invites a retry loop against a wall.
local function robloxDomain(url: string): boolean
	-- Authority only: userinfo off the front, port off the back, path never seen.
	-- Each of those is a way to hide the real host from a naive `find("roblox")`,
	-- and the frontier anchors the rest — `notroblox.com` ends in the same ten
	-- characters and is somebody else's domain.
	local host = url:match("^https?://([^/?#]+)") or ""
	host = (host:match("([^@]+)$") or host):match("^[^:]*")
	return host:lower():match("%f[%w]roblox%.com$") ~= nil
end

-- The request itself, and every rule RequestAsync enforces about one. Shared,
-- because above this line curl and wget are two flag vocabularies and below it
-- they want exactly the same thing — and a second copy is a second place for the
-- Roblox-domain rule or the body-on-GET rule to be quietly wrong in one command
-- and right in the other.
--
-- `timeoutFlag` is only ever printed: curl spells it -m and wget spells it -T,
-- and a timeout message that names the wrong one sends the reader to a flag their
-- command does not have.
local function httpRequest(opts: {
	url: string, method: string?, head: boolean?, headers: { [string]: string },
	body: string?, maxTime: string?, timeoutFlag: string,
}): (any?, string?)
	if not opts.url:match("^https?://") then
		-- curl defaults a bare host to http://. Not copied: every endpoint worth
		-- reaching is https, and silently downgrading is not a default to have.
		return nil, "URL must start with http:// or https:// — got " .. opts.url
	end
	if robloxDomain(opts.url) then
		return nil, opts.url .. " is a Roblox domain, and HttpService refuses every " ..
			"one of them. A mirror is the way in: this plugin reads the API dump " ..
			"from raw.githubusercontent.com for the same reason"
	end
	-- Data implies POST unless the verb was named, and curl's -I and wget's
	-- --spider are both a HEAD. Derived here rather than in each handler, because
	-- it is the same rule twice under two spellings.
	local method = opts.head and "HEAD"
		or (opts.method or (opts.body and "POST") or "GET"):upper()
	if not METHOD_SET[method] then
		return nil, string.format("unknown method %s — RequestAsync takes %s",
			method, table.concat(HTTP_METHODS, " "))
	end
	-- The engine's rule: RequestAsync excludes Body on these two and fails the
	-- call rather than dropping what it cannot send.
	if opts.body and (method == "GET" or method == "HEAD") then
		return nil, method .. " cannot carry a body — RequestAsync excludes it"
	end

	local timeout = CURL_TIMEOUT
	if opts.maxTime then
		local seconds = tonumber(opts.maxTime)
		if not seconds or seconds <= 0 then
			return nil, string.format("%s takes a number of seconds greater than zero — got %s",
				opts.timeoutFlag, opts.maxTime)
		end
		-- Whole seconds, because the field is an Integer, and rounded UP so that
		-- half a second stays a request that can succeed rather than becoming a
		-- zero the engine rejects outright.
		timeout = math.ceil(seconds)
	end

	-- Yielding is fine here for the same reason it is fine in Props' dump fetch,
	-- which is already reached from `cat`: tool dispatch runs after the response
	-- stream has closed. What is ruled out is blocking forever, and Timeout is
	-- what guarantees an end. See tail -f, which is refused on exactly that line.
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = opts.url, Method = method, Headers = opts.headers,
			Body = opts.body, Timeout = timeout,
		})
	end)
	if not ok then
		-- No response at all: a timeout, DNS, TLS, or HttpEnabled being off. All
		-- but the first are passed through, because the engine's own wording
		-- already names a thing the user can go and fix.
		local why = tostring(response)
		local lower = why:lower()
		if lower:find("timeout", 1, true) or lower:find("timed out", 1, true) then
			-- The budget is ours, so a timeout has to say so. Otherwise the number
			-- the request actually ran against appears nowhere.
			why ..= string.format(" (gave it %ds; %s sets that, up to the engine's own limit)",
				timeout, opts.timeoutFlag)
		end
		return nil, why
	end
	return response, nil
end

-- curl's --write-out, filled from what RequestAsync actually hands back.
--
-- The refusal this replaces claimed these were "curl's own internals", which was
-- only true of some of them: a status code and a content type are exactly what
-- the response carries. What is genuinely missing is the connection phases —
-- time_namelookup, time_connect, time_appconnect, remote_ip, num_redirects,
-- ssl_verify_result — because RequestAsync is one call that returns one table and
-- never reports what happened inside it.
--
-- time_total is wall time around the call, which is honest but coarser than
-- curl's: it includes the scheduler getting back to us, not just the transfer.
local function writeOutValues(response: any, url: string, elapsed: number)
	local body = response.Body or ""
	local contentType, count = "", 0
	for name, value in pairs(response.Headers or {}) do
		count += 1
		if name:lower() == "content-type" then
			contentType = tostring(value)
		end
	end
	return {
		http_code = tostring(response.StatusCode),
		response_code = tostring(response.StatusCode),
		content_type = contentType,
		size_download = tostring(#body),
		num_headers = tostring(count),
		url = url,
		url_effective = url,
		time_total = string.format("%.6f", elapsed),
		speed_download = string.format("%.3f", elapsed > 0 and #body / elapsed or 0),
	}
end

-- Expand a --write-out format. An unknown %{name} is an ERROR rather than an
-- empty string: a format that quietly drops %{time_connect} prints a number that
-- reads as a measurement and is not one.
local function expandWriteOut(format: string, values: { [string]: string }): (string?, string?)
	local unknown: string? = nil
	-- [%w_], not %w: Lua's %w has no underscore, and every name curl uses has one.
	local out = format:gsub("%%{([%w_]+)}", function(name)
		local value = values[name:lower()]
		if not value then
			unknown = unknown or name
		end
		return value or ""
	end)
	if unknown then
		local known: { string } = {}
		for name in pairs(values) do
			known[#known + 1] = name
		end
		table.sort(known)
		return nil, string.format(
			"-w %%{%s} is not something RequestAsync reports — it returns one response " ..
			"and nothing about the connection behind it. Available: %s",
			unknown, table.concat(known, " "))
	end
	-- curl's own escapes, and %% for a literal percent.
	out = out:gsub("\\([ntr\\])", { n = "\n", t = "\t", r = "\r", ["\\"] = "\\" })
	return (out:gsub("%%%%", "%%")), nil
end

-- The one URL both take. Real curl fetches several and concatenates the bodies;
-- refused for both, because two documents run together with no marker between
-- them is a result nothing downstream can take apart again.
local function oneUrl(cmd: string, operands: { string }): (string?, string?)
	if #operands == 0 then
		return nil, fail(cmd, "requires a URL")
	end
	if #operands > 1 then
		return nil, fail(cmd, "one URL at a time")
	end
	return operands[1], nil
end

-- The head of a response as output lines, plus whether its status makes the call
-- a failure. What happens to the BODY differs between the two commands, and with
-- -w even whether the failure counts, so both decisions stay with the caller —
-- `fail` sets the flag `&&` and `||` read, and calling it on a path that then
-- returns successfully would mark a working command failed.
--
-- The rule itself is shared: real curl prints an error page and exits 0, and real
-- wget saves it; -f and --content-on-error are what change that. Inverted here
-- for both, because a 404's HTML flowing into a pipe, or saved under the name of
-- the document you wanted, looks exactly like the document.
local function renderResponse(response: any, showHead: boolean): ({ string }, boolean)
	local status = string.format("HTTP %d %s", response.StatusCode, response.StatusMessage or "")
	local out: { string } = {}
	-- curl -i/-I and wget -S/--spider.
	if showHead then
		out[1] = status
		local names: { string } = {}
		for name in pairs(response.Headers or {}) do
			names[#names + 1] = name
		end
		table.sort(names)
		for _, name in ipairs(names) do
			out[#out + 1] = name .. ": " .. tostring(response.Headers[name])
		end
		out[#out + 1] = ""
	elseif not response.Success then
		-- The status leads when the head was not printed, or the failure is an
		-- HTML page with no number attached to it.
		out[1] = status
	end
	return out, not response.Success
end

HANDLERS.curl = function(self, argv)
	local flags, values, operands = parse(argv)
	local url, urlErr = oneUrl("curl", operands)
	if not url then return urlErr end

	local headers, headerErr = parseHeaders(values["-H"])
	if not headers then return fail("curl", headerErr) end
	for flag, spec in pairs(HEADER_FLAGS) do
		local value = valueOf(values, flag)
		if value then
			headers[spec.header] = (spec.prefix or "") .. value
		end
	end

	-- Data, assembled in curl's order: every -d and --data-urlencode joined with
	-- &, which is what curl does with repeated data flags rather than keeping the
	-- last one.
	local data: { string } = {}
	for _, value in ipairs(values["-d"] or {}) do
		if value:sub(1, 1) == "@" then
			local fromFile, readErr = bodyFromScript(self, value:sub(2))
			if not fromFile then return fail("curl", readErr) end
			data[#data + 1] = fromFile
		else
			data[#data + 1] = value
		end
	end
	for _, pair in ipairs(values["--data-urlencode"] or {}) do
		-- curl's two common forms: `name=content` encodes the content only, a bare
		-- string encodes the whole thing. The `@file` forms are left out, since -d
		-- @path already covers reading a body out of the DataModel.
		local name, content = pair:match("^([^=@]*)=(.*)$")
		if name and name ~= "" then
			data[#data + 1] = name .. "=" .. HttpService:UrlEncode(content)
		else
			data[#data + 1] = HttpService:UrlEncode((pair:gsub("^=", "")))
		end
	end
	local body: string? = #data > 0 and table.concat(data, "&") or nil

	-- --json is -d plus the two headers everyone forgets, which is the whole of
	-- why it exists alongside -d.
	local json = valueOf(values, "--json")
	if json then
		body = json
		headers["content-type"] = headers["content-type"] or "application/json"
		headers["accept"] = headers["accept"] or "application/json"
	elseif body then
		headers["content-type"] = headers["content-type"] or "application/x-www-form-urlencoded"
	end

	-- -G moves the data onto the URL and leaves the request a GET, which is the
	-- only way to send a long query through a body-less method.
	if flags["-G"] and body then
		url = appendQuery(url, body)
		body = nil
	end

	-- Where the body goes, settled before the fetch for the same reason wget does
	-- it: -o naming a path that cannot be written is worth knowing before the
	-- request rather than after it.
	local saveTo: string? = valueOf(values, "-o")
	if flags["-O"] then
		saveTo = nameFromUrl(url)
		if not saveTo then
			return fail("curl", "-O takes the name from the URL, and " .. url ..
				" has none — name one with -o, or drop -O to print the body")
		end
	end

	local started = os.clock()
	local response, requestErr = httpRequest({
		url = url, method = valueOf(values, "-X"), head = flags["-I"],
		headers = headers, body = body,
		maxTime = valueOf(values, "-m"), timeoutFlag = "-m",
	})
	if not response then return fail("curl", requestErr) end
	local elapsed = os.clock() - started

	local format = valueOf(values, "-w")
	local out, statusFailed = renderResponse(response, flags["-i"] or flags["-I"])
	-- -w is a request for the status, so the caller is already handling it and
	-- the non-2xx inversion only gets in the way: `-o /dev/null -w "%{http_code}"`
	-- exists precisely to read a 404 without treating it as a broken call. Every
	-- other shape keeps the failure, because nothing else asked to see the number.
	if statusFailed and not format then
		table.insert(out, response.Body or "")
		return fail("curl", table.concat(out, "\n"))
	end

	-- -I asked for headers alone, and HEAD has no body either way.
	if not flags["-I"] then
		if saveTo then
			-- -o writes the body instead of printing it, and /dev/null throws it
			-- away. Unlike wget this says nothing about the write: curl is silent
			-- about where the body went, and -w is how you ask it to speak.
			if saveTo ~= DEV_NULL then
				local wrote, writeErr = self:write(saveTo, response.Body or "")
				if not wrote then return fail("curl", writeErr) end
			end
		else
			table.insert(out, response.Body or "")
		end
	end

	if format then
		local report, formatErr = expandWriteOut(format,
			writeOutValues(response, url, elapsed))
		if not report then return fail("curl", formatErr) end
		table.insert(out, report)
	end
	return table.concat(out, "\n")
end

-- wget: fetch a URL and SAVE it.
--
-- That default is the whole of what makes it wget rather than a second spelling
-- of curl, so it is the part kept, and it is the ONLY part: the request, the
-- headers and the non-2xx rule are the same functions curl calls. Aliasing the
-- two outright would have been shorter and would have made `wget URL` print to
-- stdout, which is wget's `-O -` and not wget.
--
-- Left out is the half of wget that is actually wget: -r, -m and the rest walk
-- links and rebuild a tree on disk, and there is no tree here to rebuild into.
-- Those are refused by name in SPECS rather than approximated.
HANDLERS.wget = function(self, argv)
	local flags, values, operands = parse(argv)
	local url, urlErr = oneUrl("wget", operands)
	if not url then return urlErr end

	local headers, headerErr = parseHeaders(values["--header"])
	if not headers then return fail("wget", headerErr) end

	local body = valueOf(values, "--post-data")
	local postFile = valueOf(values, "--post-file")
	if postFile then
		local fromFile, readErr = bodyFromScript(self, postFile)
		if not fromFile then return fail("wget", readErr) end
		body = fromFile
	end
	if body then
		headers["content-type"] = headers["content-type"] or "application/x-www-form-urlencoded"
	end

	-- Where this is going, decided BEFORE the request rather than after it.
	-- Finding out there is no name to save under once the body is already here
	-- spends a fetch to learn something the URL said all along, and on a service
	-- that counts requests it spends one that counted.
	local target = valueOf(values, "-O")
	local path: string? = nil
	if target ~= "-" and not flags["--spider"] then
		path = target or nameFromUrl(url)
		if not path then
			-- wget writes index.html here. Not copied: inventing a name for a
			-- script in someone's place is a guess, and -O costs one argument.
			return fail("wget",
				"no filename in " .. url .. " — name one with -O, or -O - for stdout")
		end
	end

	-- --spider asks whether a URL is there, which is a HEAD and never a download.
	local response, requestErr = httpRequest({
		url = url, method = valueOf(values, "--method"), head = flags["--spider"],
		headers = headers, body = body,
		maxTime = valueOf(values, "-T"), timeoutFlag = "-T",
	})
	if not response then return fail("wget", requestErr) end

	-- Nothing is saved when the fetch failed, which is wget's own rule too.
	local out, statusFailed = renderResponse(response, flags["-S"] or flags["--spider"])
	if statusFailed then
		table.insert(out, response.Body or "")
		return fail("wget", table.concat(out, "\n"))
	end
	if flags["--spider"] then
		return table.concat(out, "\n")
	end

	local content = response.Body or ""
	if not path then
		-- -O -, wget's spelling for stdout, and the one form that composes with
		-- a pipe.
		table.insert(out, content)
		return table.concat(out, "\n")
	end
	-- Terminal:write creates the script, records undo and updates the observed
	-- mtime, which is every part of writing a file this shell already knows how to
	-- do. The parent has to exist, the same as for `> path`.
	local wrote, writeErr = self:write(path, content)
	if not wrote then return fail("wget", writeErr) end
	if flags["-q"] then
		return table.concat(out, "\n")
	end
	table.insert(out, wrote)
	return table.concat(out, "\n")
end

-- git
--
-- Against the host's API rather than git's wire protocol. That is not a shortcut
-- taken for size: the whole object model is exposed as JSON, so a commit is
-- three requests and needs neither a zlib nor a packfile, and this engine hands
-- over SHA-1 natively, so the ids are still real git ids and can be checked
-- against the ones the host reports.
--
-- The reads need no write token, which means they run against any public
-- repository, and they are what proves the id comparison end to end before
-- anything is pushed. commit is the other half and needs one.
--
-- Subcommands are OPERANDS, not flags, so SPECS.git declares only the flags the
-- subcommands themselves take. Placed after httpRequest because it needs it.
--
-- Every subcommand this handler answers, written once. The two messages that
-- name them had both gone stale in the same direction — they still advertised
-- config/status/diff long after add, commit, log, pull and reset landed, which
-- is a model reading "this cannot commit" off a string and never trying. See
-- Shell.COMMANDS, derived one level up for exactly this reason; a table-driven
-- dispatch would derive this too, but every branch below closes over flags,
-- values, operands and remoteConfig, so it is a rewrite to fix a list. The
-- self-test walks these instead and fails on any name with no branch behind it.
local GIT_SUBS = { "add", "clone", "commit", "config", "diff", "log", "pull", "reset",
	"show", "status" }
local GIT_SUB_LIST = table.concat(GIT_SUBS, " ")
-- One response header, whatever case the engine handed it back in. RequestAsync
-- does not document whether it normalises them, and a check that matches only
-- `x-ratelimit-remaining` would silently never fire against a host that spells
-- it `X-RateLimit-Remaining`, which is exactly how GitHub spells it.
local function headerValue(response: any, wanted: string): string?
	for name, value in pairs(response.Headers or {}) do
		if name:lower() == wanted then
			return tostring(value)
		end
	end
	return nil
end

local function githubCall(url: string, method: string, body: string?): (any?, string?, number?)
	local response, err = httpRequest({
		url = url, method = method, headers = Git.headers(), body = body, timeoutFlag = "-m",
	})
	if not response then
		return nil, err
	end
	local code = response.StatusCode
	-- Named individually, because "404" against a repository that plainly exists
	-- reads as a bug in this code rather than as a branch nobody has pushed yet.
	if code == 404 then
		return nil, "not found — check the owner, repo and branch, or whether the " ..
			"token can see a private repository", code
	elseif (code == 403 or code == 429) and headerValue(response, "x-ratelimit-remaining") == "0" then
		-- A spent rate limit arrives as a 403 — lately also a 429 — shaped exactly
		-- like a rejected token, so without this the answer is "your token is
		-- wrong" to somebody whose token is fine. Clone is what makes it the
		-- likely failure rather than a curiosity: one request per file, against
		-- sixty an hour with no token at all.
		local reset = tonumber(headerValue(response, "x-ratelimit-reset") or "")
		local minutes = reset and math.max(1, math.ceil((reset - os.time()) / 60))
		return nil, string.format("GitHub's rate limit is spent%s — %s",
			minutes and string.format(", resets in ~%d min", minutes) or "",
			Git.token() == ""
				and "that is 60 requests an hour without one; `git config token <pat>` raises it to 5000"
				or "there is a ceiling with a token too, and this window is done"), code
	elseif code == 401 or code == 403 then
		return nil, Git.token() == ""
			and "unauthorized, and no token is set — `git config token <pat>` for a private repo"
			or "unauthorized — the token is wrong, expired, or lacks Contents access", code
	elseif code >= 300 then
		return nil, string.format("HTTP %d: %s", code, tostring(response.Body):sub(1, 200)), code
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not ok then
		return nil, "the response was not JSON"
	end
	return decoded, nil
end

local function githubJson(url: string): (any?, string?)
	return githubCall(url, "GET", nil)
end

-- Every blob in a tree, by path. `ref` is the branch when comparing against what
-- the remote has, or a tree sha when reading back one just written.
local function remoteTree(cfg: any, ref: string?): ({ [string]: string }?, string?)
	local data, err = githubJson(Git.treeUrl(cfg, ref))
	if not data then
		return nil, err
	end
	-- A recursive tree past the host's own limits comes back truncated WITH A
	-- FLAG. Reporting a partial tree as the whole one would show every file it
	-- left out as deleted, which is the most alarming possible way to be wrong.
	if data.truncated then
		return nil, "the remote tree came back truncated, so every file it left " ..
			"out would read as deleted — this repo is too large to compare this way"
	end
	local byPath: { [string]: string } = {}
	for _, entry in ipairs(data.tree or {}) do
		if entry.type == "blob" then
			byPath[entry.path] = entry.sha
		end
	end
	return byPath, nil
end

-- One remote file's text. The host wraps base64 at a fixed width, so the
-- whitespace has to go before decoding or the decoder rejects it.
local function remoteBlob(cfg: any, sha: string): (string?, string?)
	local data, err = githubJson(Git.blobUrl(cfg, sha))
	if not data then
		return nil, err
	end
	if data.encoding ~= "base64" then
		return nil, "unexpected blob encoding: " .. tostring(data.encoding)
	end
	local text, decodeErr = Git.decodeBase64(tostring(data.content))
	if not text then
		return nil, "could not decode the blob: " .. tostring(decodeErr)
	end
	return text, nil
end

-- Fetched files into the DataModel: containers first, then sources, all inside
-- one undo recording. Shared by pull and clone, which differ in WHICH paths they
-- hand over and not at all in what happens to them here — a second copy of this
-- is a second place for the service guard or the undo wrapper to be quietly
-- wrong in one direction and right in the other.
--
-- Paths are root-relative with no leading slash, the shape remoteTree returns.
-- Clone prefixes its destination onto them before calling, so the walk below is
-- the same walk either way.
local function materialize(self: any, files: { { path: string, source: string } },
	label: string): (number, { string }, string?)
	local written = 0
	local failures: { string } = {}
	-- Which containers are themselves a script, from the init files in the batch.
	-- Consumed as the walk reaches them, so an init file is never also written as
	-- a child under the container it became — whichever order the two arrive in.
	local initFor = Git.initContainers(files)
	local consumed: { [string]: boolean } = {}
	local _, undoErr = withUndo(label, function()
		for _, item in ipairs(files) do
			-- Containers first. The leading segment is a service and already
			-- exists; anything else missing at the top would mean inventing a
			-- container directly under the DataModel root, which this refuses
			-- rather than quietly polluting the place.
			local segments: { string } = {}
			for segment in item.path:gmatch("[^/]+") do
				segments[#segments + 1] = segment
			end
			local walked = ""
			local blocked: string? = nil
			for index = 1, #segments - 1 do
				local parentPath = walked == "" and "/" or walked
				walked ..= "/" .. segments[index]
				local init = initFor[walked]
				if not self:resolve(walked) then
					if index == 1 then
						blocked = walked .. " is not a service in this place"
						break
					end
					-- Born the right class rather than made a Folder and converted:
					-- a ClassName cannot be changed, and reparenting a subtree into
					-- a replacement is a bigger operation than this is worth.
					local _, createErr = self:create(init and init.class or "Folder",
						segments[index], parentPath)
					if createErr then
						blocked = createErr
						break
					end
				end
				-- Just created or already there, the source goes into the container
				-- itself. A container that is NOT a script is the one shape this
				-- cannot fix, and writing the init file as an ordinary child there
				-- would leave a module nothing can require and say nothing about it.
				if init and not consumed[init.path] then
					consumed[init.path] = true
					local target = self:resolve(walked)
					if target and isScript(target) then
						local _, initErr = self:write(walked, init.source)
						if initErr then
							failures[#failures + 1] = init.path .. ": " .. tostring(initErr)
						else
							written += 1
						end
					else
						failures[#failures + 1] = string.format("%s: %s is not a script here, " ..
							"and an init file means the container IS the script — remove or " ..
							"rename it and run this again", init.path, walked)
					end
				end
			end
			if blocked then
				failures[#failures + 1] = item.path .. ": " .. blocked
			elseif not consumed[item.path] then
				local _, writeErr = self:write("/" .. item.path, item.source)
				if writeErr then
					failures[#failures + 1] = item.path .. ": " .. tostring(writeErr)
				else
					written += 1
				end
			end
		end
	end)
	return written, failures, undoErr
end

HANDLERS.git = function(self, argv)
	local flags, values, operands = parse(argv)
	local sub = operands[1]
	if not sub or sub == "" then
		return fail("git", "needs a subcommand — " .. GIT_SUB_LIST)
	end
	local usable, why = Git.available()
	if not usable then
		return fail("git", why)
	end

	-- Every subcommand that reaches the remote opens with the same question, and
	-- asking it six separate times was six places for the answer to drift.
	local function remoteConfig(): (any?, string?)
		local cfg = Git.config()
		local ready, err = Git.configured(cfg)
		if not ready then
			return nil, err
		end
		return cfg
	end

	if sub == "config" then
		local name, value = operands[2], operands[3]
		if not name then
			local cfg = Git.config()
			-- The token is shown as present or absent and never printed. It ends up
			-- in a tool result otherwise, which is a transcript, which is stored.
			return table.concat({
				string.format("remote  %s", cfg.owner ~= "" and (cfg.owner .. "/" .. cfg.repo) or "(unset)"),
				string.format("branch  %s", cfg.branch),
				string.format("token   %s", Git.token() ~= "" and "(set)" or "(unset)"),
			}, "\n")
		end
		if not value then
			return fail("git", string.format("`git config %s <value>` sets it", name))
		end
		if name == "remote" then
			local ok, remoteErr = Git.setRemote(value)
			if not ok then
				return fail("git", remoteErr)
			end
			return "remote  " .. value
		end
		local ok, setErr = Git.setConfig(name, value)
		if not ok then
			return fail("git", setErr)
		end
		return string.format("%s  %s", name, name == "token" and "(set)" or value)
	end

	-- clone: a repository this place did not write, read into it.
	--
	-- The one subcommand that reads a repo other than the configured one, which
	-- is why it builds its own cfg instead of going through remoteConfig — and
	-- why it leaves the configured remote ALONE. Real git sets a remote up on
	-- clone; here that setting is the place's own push target, and repointing it
	-- because somebody read a library is how the next commit lands in the wrong
	-- repository.
	--
	-- A configured token still rides along in Git.headers. That is the host that
	-- issued it, so nothing reaches anywhere new, and it is what makes a private
	-- repository and the 5000/hr limit work.
	if sub == "clone" then
		local owner, repo = Git.parseSlug(operands[2])
		if not owner or not repo then
			return fail("git", string.format("`git clone <%s> [dest]` — got %q",
				Git.SLUG_FORMS, tostring(operands[2] or "")))
		end
		-- HEAD is a ref the trees API resolves to the default branch, so nothing
		-- has to guess between main and master, and the same slot takes a tag, so
		-- --branch pins a version. Long form only: -b is already `git diff
		-- --ignore-space-change` in SPECS, and taking it would break that silently.
		local ref = valueOf(values, "--branch") or "HEAD"
		local cfg = { owner = owner, repo = repo, branch = ref }
		-- git's own default is the repository's name under the cwd, and that is
		-- what this does — except at the DataModel root, where it cannot. The cwd
		-- starts at `game`, a service is the shallowest thing that exists there,
		-- and materialize refuses to invent a container beside one. So `git clone
		-- owner/repo` typed as the first command of a session had every file come
		-- back "not a service in this place" — a default that fails at the default
		-- cwd is not a default.
		--
		-- The fallback is the scratch folder the run tool already names, which is
		-- also the honest place for a repository nobody has decided where to keep
		-- yet. Anywhere below the root, and for any named destination, git's rule
		-- stands untouched, and the path is printed either way so the answer to
		-- "where did it go" is in the output rather than in this comment.
		local dest = operands[3]
			or (if self:current() == game then "/ServerStorage/tmp/" .. repo else repo)
		local existing = self:resolve(dest)
		local occupied = existing and #existing:GetChildren() or 0
		if occupied > 0 and not flags["-f"] then
			return fail("git", string.format("%s already has %d child%s — `git clone -f` " ..
				"writes into it anyway", instancePath(existing :: Instance), occupied,
				occupied == 1 and "" or "ren"))
		end

		local remote, remoteErr = remoteTree(cfg)
		if not remote then
			return fail("git", remoteErr)
		end
		local paths, notScripts = Git.scriptPaths(remote, flags["-A"])
		if #paths == 0 then
			return fail("git", string.format("nothing to clone from %s/%s@%s — %d file%s and " ..
				"not a script among them; `git clone -A` takes the rest too",
				owner, repo, ref, notScripts, notScripts == 1 and "" or "s"))
		end
		-- One blob request per file, against 60 an hour unauthenticated. A
		-- repository this size is a place rather than a library, and pull is
		-- already the way to take a whole one on — this is a redirect, not a wall.
		if #paths > MAX_LIST then
			return fail("git", string.format("%s/%s has %d scripts and each one is its own " ..
				"request. That is a place, not a library: `git config remote %s/%s` then " ..
				"`git pull` is how a whole repository comes across",
				owner, repo, #paths, owner, repo))
		end

		-- An existing destination is normalised through the DataModel, which is
		-- what turns `.`, `..` and a case-folded service name into the one path
		-- the walk can build on. One that does not exist yet has no such answer
		-- and is taken as written.
		local base = existing and instancePath(existing)
			or (dest:sub(1, 1) == "/" and dest or (self:pwd() .. "/" .. dest))
		base = base:gsub("//+", "/"):gsub("^/", ""):gsub("/$", "")
		local prefix = base == "" and "" or (base .. "/")

		-- Fetched before anything is written, for the reason pull does it: a
		-- yield inside an open undo recording, and a half-applied clone that
		-- cannot be taken back in one step.
		local fetched: { { path: string, source: string } } = {}
		for _, path in ipairs(paths) do
			local text, blobErr = remoteBlob(cfg, remote[path])
			if not text then
				return fail("git", string.format("%s: %s (nothing has been written)",
					path, tostring(blobErr)))
			end
			fetched[#fetched + 1] = { path = prefix .. path, source = text }
		end

		local written, failures, undoErr = materialize(self, fetched, "agent: git clone " .. repo)
		if undoErr then
			return fail("git", undoErr)
		end
		local out: { string } = {
			string.format("Cloned %s/%s@%s into /%s — %d file%s",
				owner, repo, ref, base, written, written == 1 and "" or "s"),
		}
		if notScripts > 0 then
			-- Two different facts, so two messages. Without -A the rest is simply
			-- not asked for; WITH it, what is left cannot round-trip, and saying
			-- "use -A" to somebody who just used it is the unhelpful kind of true.
			out[#out + 1] = if flags["-A"]
				then string.format("%d file%s skipped — a name with no extension cannot be " ..
					"told from a script's, so it would commit back as .luau",
					notScripts, notScripts == 1 and "" or "s")
				else string.format("%d non-script file%s skipped — `git clone -A` takes them " ..
					"too, as ModuleScripts holding their own text",
					notScripts, notScripts == 1 and "" or "s")
		end
		for _, note in ipairs(failures) do
			out[#out + 1] = "failed: " .. note
		end
		return table.concat(out, "\n")
	end

	-- Staging records PATHS, never content: `git commit` reads each one's source
	-- at the moment it commits, which is what keeps the index a list of strings
	-- instead of the object database this design does without.
	if sub == "reset" then
		local paths: { string } = {}
		table.move(operands, 2, #operands, 1, paths)
		Git.unstage(#paths > 0 and paths or nil)
		local left = Git.staged()
		return #left == 0 and "nothing staged"
			or string.format("%d still staged", #left)
	end

	if sub == "add" then
		local named: { string } = {}
		table.move(operands, 2, #operands, 1, named)
		if #named == 0 and not flags["-A"] then
			return fail("git", "name a path, or `git add -A` for everything that changed")
		end
		if #named > 0 then
			-- Validated against the working tree, which needs no request: a typo
			-- staged silently would surface three steps later as a missing file.
			--
			-- Which is also why a DELETION cannot be named here, only staged with
			-- -A. A path that is not in the working tree is either a file someone
			-- removed or a name someone mistyped, and this end cannot tell the two
			-- apart without asking the remote. Guessing "deletion" is the
			-- expensive way to be wrong: treePayload turns a staged-but-absent
			-- path into `"sha": null`, and the commit deletes it on the remote.
			-- The old wording sent the reader to `git status`, which lists
			-- deletions this then refused.
			local working = Git.walk(game)
			for _, path in ipairs(named) do
				if not working[path] then
					return fail("git", string.format("%q is not a script here, so naming it " ..
						"cannot stage it — a named path is checked against what IS here, " ..
						"which is what stops a typo from committing a deletion. " ..
						"`git add -A` stages the real ones", path))
				end
			end
			Git.stage(named)
			return string.format("%d staged, %d total", #named, #Git.staged())
		end
		-- -A is every CHANGE, which includes the deletions, and those can only be
		-- known by asking what the remote still has.
		local cfg, configErr = remoteConfig()
		if not cfg then
			return fail("git", configErr)
		end
		local remote, remoteErr = remoteTree(cfg)
		if not remote then
			return fail("git", remoteErr)
		end
		local working = Git.walk(game)
		local changed = Git.changedPaths(Git.compare(working, remote))
		Git.stage(changed)
		return #changed == 0 and "nothing to stage"
			or string.format("%d staged", #changed)
	end

	if sub == "commit" then
		local message = valueOf(values, "-m")
		if not message or message == "" then
			return fail("git", "a commit needs a message — `git commit -m \"what changed\"`")
		end
		if Git.token() == "" then
			return fail("git", "committing needs a token — `git config token <pat>`, " ..
				"fine-grained with Contents: write")
		end
		local cfg, configErr = remoteConfig()
		if not cfg then
			return fail("git", configErr)
		end
		local staged = Git.staged()
		if #staged == 0 then
			return fail("git", "nothing staged — `git add -A` stages every change")
		end

		-- One request for both halves a commit needs: the head to parent from and
		-- the tree to build on. A 404 here is not a failure — it is a branch that
		-- does not exist yet, which is what a freshly created repository looks
		-- like. That case builds a ROOT commit instead: no base tree to extend, no
		-- parent to follow, and the ref has to be created rather than moved.
		local branch, branchErr, branchCode = githubCall(Git.branchUrl(cfg), "GET", nil)
		local parentSha: string? = nil
		local baseSha: string? = nil
		if branch then
			local head = branch.commit
			local tree = head and head.commit and head.commit.tree
			if not head or not head.sha or not tree or not tree.sha then
				return fail("git", "the branch carried no head commit to build on")
			end
			parentSha, baseSha = head.sha, tree.sha
		elseif branchCode ~= 404 then
			return fail("git", branchErr)
		end

		local working = Git.walk(game)
		local entries = Git.treePayload(working, staged)
		-- Chained through base_tree rather than sent as one body: a first commit
		-- of a whole place measures over a megabyte, and the engine documents no
		-- size limit to size it against. Each chunk builds on the last, so the
		-- number of requests changes and the resulting commit does not.
		local chunks = Git.chunkPayload(entries)
		local treeSha = baseSha
		for index, chunk in ipairs(chunks) do
			-- base_tree is omitted on the first chunk of a root commit: there is no
			-- tree to build on, and a nil field would simply vanish from the JSON
			-- rather than say so.
			local encoded = treeSha
				and HttpService:JSONEncode({ base_tree = treeSha, tree = chunk })
				or HttpService:JSONEncode({ tree = chunk })
			local body, nullErr = Git.encodeTree(encoded)
			if not body then
				return fail("git", nullErr)
			end
			local tree, treeErr = githubCall(Git.newTreeUrl(cfg), "POST", body)
			if not tree or not tree.sha then
				return fail("git", string.format("tree %d of %d: %s", index, #chunks,
					tostring(treeErr or "the remote returned a tree with no sha")))
			end
			treeSha = tree.sha
		end

		-- The check this design rests on: the remote hashed the blobs it just
		-- wrote, and this end hashed them before sending. Read the FINISHED tree
		-- back to do it — a tree response carries top-level entries only, so
		-- checking against one matched no nested path and passed on every commit
		-- without ever comparing anything.
		local created, createdErr = remoteTree(cfg, treeSha)
		if not created then
			return fail("git", "could not read back the tree to verify it: " .. tostring(createdErr))
		end
		local verified, verifyErr = Git.verifyTree(created, working, staged)
		if not verified then
			return fail("git", tostring(verifyErr) .. " — the object model is wrong, " ..
				"so this commit has not been made")
		end

		-- `parents` is OMITTED for a root commit rather than sent empty. The API
		-- reads either as a root, but an empty Luau table encodes as {} and not
		-- [], so the field that is not there is the one that cannot be wrong.
		local commitBody = parentSha
			and HttpService:JSONEncode({ message = message, tree = treeSha, parents = { parentSha } })
			or HttpService:JSONEncode({ message = message, tree = treeSha })
		local commit, commitErr = githubCall(Git.newCommitUrl(cfg), "POST", commitBody)
		if not commit or not commit.sha then
			return fail("git", commitErr or "the remote returned a commit with no sha")
		end
		-- Until a ref points at it, that commit is unreachable and will be
		-- collected. Moving an existing branch and creating a new one are two
		-- different endpoints, not one endpoint with two verbs.
		local moved, refErr
		if parentSha then
			moved, refErr = githubCall(Git.refUrl(cfg), "PATCH",
				HttpService:JSONEncode({ sha = commit.sha }))
		else
			moved, refErr = githubCall(Git.newRefUrl(cfg), "POST",
				HttpService:JSONEncode({ ref = Git.refName(cfg), sha = commit.sha }))
		end
		if not moved then
			return fail("git", string.format("the commit %s was written but the branch " ..
				"could not be %s it: %s", commit.sha:sub(1, 7),
				parentSha and "moved to" or "created at", tostring(refErr)))
		end
		Git.unstage()
		return string.format("[%s%s %s] %s\n %d file%s changed",
			cfg.branch, parentSha and "" or " (root-commit)", commit.sha:sub(1, 7),
			message, #staged, #staged == 1 and "" or "s")
	end

	if sub == "log" then
		local cfg, configErr = remoteConfig()
		if not cfg then
			return fail("git", configErr)
		end
		local count = numberOf(values, "-n") or 20
		-- A path narrows the log to the commits that touched it, which is the
		-- question the whole log cannot answer: when did THIS change. Encoded
		-- here, where HttpService already lives, because an instance name may
		-- carry a space and the query would end at it.
		local only = operands[2]
		local data, logErr = githubJson(Git.logUrl(cfg, math.min(count, MAX_LIST),
			only and HttpService:UrlEncode(only) or nil))
		if not data then
			return fail("git", logErr)
		end
		local out: { string } = {}
		for _, entry in ipairs(data) do
			local commit = entry.commit or {}
			local author = commit.author or {}
			-- The first line only. A commit body is prose nobody asked for here,
			-- and a log that wraps is a log nothing can scan.
			local subject = tostring(commit.message or ""):match("^([^\n]*)") or ""
			out[#out + 1] = string.format("%s  %s  %s  %s",
				tostring(entry.sha):sub(1, 7), tostring(author.date or ""):sub(1, 10),
				tostring(author.name or "?"), subject)
		end
		-- A path nothing has touched comes back as an empty list rather than a 404,
		-- so the empty answer has to name what was asked or it reads as "this
		-- repository has no commits".
		if #out == 0 then
			return only and ("no commits touch " .. only) or "no commits"
		end
		return table.concat(out, "\n")
	end

	-- show: one commit, with the host's own rendering of its patch. The only
	-- read here that does no diffing — GitHub returns each file's hunks already
	-- in unified format, so this is one request where `git diff` is one blob per
	-- file plus the comparison.
	if sub == "show" then
		local sha = operands[2]
		if not sha or sha == "" then
			return fail("git", "`git show <sha> [path]` — `git log` lists the shas, and " ..
				"the short form it prints is enough")
		end
		local cfg, configErr = remoteConfig()
		if not cfg then
			return fail("git", configErr)
		end
		local data, showErr = githubJson(Git.commitUrl(cfg, HttpService:UrlEncode(sha)))
		if not data then
			return fail("git", showErr)
		end
		local commit = data.commit or {}
		local author = commit.author or {}
		local out: { string } = {
			"commit " .. tostring(data.sha),
			string.format("Author: %s <%s>", tostring(author.name or "?"),
				tostring(author.email or "")),
			"Date:   " .. tostring(author.date or ""),
			"",
		}
		-- Indented four, which is how git renders a message and what keeps a body
		-- line starting with `-` from reading as a diff line further down.
		for _, line in ipairs(splitLines(tostring(commit.message or ""))) do
			out[#out + 1] = "    " .. line
		end
		local stats = data.stats or {}
		out[#out + 1] = ""
		out[#out + 1] = string.format("%d file%s changed, +%d -%d", #(data.files or {}),
			#(data.files or {}) == 1 and "" or "s", tonumber(stats.additions) or 0,
			tonumber(stats.deletions) or 0)
		out[#out + 1] = ""

		local files = data.files or {}
		-- A named file, git's `git show <sha> -- <path>` without the separator no
		-- shell here needs. It is also what makes the budget below a redirect
		-- rather than a wall.
		local only = operands[3]
		if only then
			local matched: { any } = {}
			for _, file in ipairs(files) do
				if tostring(file.filename) == only
					or tostring(file.previous_filename or "") == only then
					matched[#matched + 1] = file
				end
			end
			if #matched == 0 then
				local names: { string } = {}
				for index, file in ipairs(files) do
					if index > 20 then
						names[#names + 1] = string.format("… %d more", #files - 20)
						break
					end
					names[#names + 1] = tostring(file.filename)
				end
				return fail("git", string.format("%s does not touch %q — it touches %s",
					tostring(data.sha):sub(1, 7), only, table.concat(names, " ")))
			end
			files = matched
		end
		-- The headers cost one line each and are what the path form needs, so they
		-- are always printed; the PATCHES spend a budget. This is the one read
		-- here that is otherwise unbounded — twenty files at five hundred lines is
		-- ten thousand into a context window, which is the cost MAX_CAT_LINES
		-- exists to stop one file from spending.
		--
		-- ponytail: 400 lines, sitting near `cat`'s own 1000 for a single file
		-- while covering several. Raise it if `git show <sha> <path>` turns out to
		-- be the common call rather than the escape hatch.
		local budget = 400
		local spent = 0
		-- The `a/`, `b/` and /dev/null spellings are `git diff`'s own, three
		-- branches up, so the two commands render a change the same way even
		-- though only one of them computed it.
		for index, file in ipairs(files) do
			if index > 20 then
				out[#out + 1] = string.format("… %d more files in this commit", #files - 20)
				break
			end
			local name = tostring(file.filename)
			local was = tostring(file.previous_filename or name)
			local status = tostring(file.status)
			out[#out + 1] = string.format("diff --git a/%s b/%s", was, name)
			out[#out + 1] = "--- " .. (status == "added" and "/dev/null" or ("a/" .. was))
			out[#out + 1] = "+++ " .. (status == "removed" and "/dev/null" or ("b/" .. name))
			-- The host omits the patch for a file it will not render — a binary, or
			-- one simply too large. A header with nothing under it would read as an
			-- empty diff, which is the opposite of what happened.
			if not file.patch then
				out[#out + 1] = string.format("  (%s, +%d -%d; the host renders no patch for this one)",
					status, tonumber(file.additions) or 0, tonumber(file.deletions) or 0)
			else
				local lines = splitLines(tostring(file.patch))
				if spent >= budget then
					out[#out + 1] = string.format("  (%d lines; `git show %s %s` for it)",
						#lines, tostring(data.sha):sub(1, 7), name)
				elseif spent + #lines > budget then
					local room = budget - spent
					for cut = 1, room do
						out[#out + 1] = lines[cut]
					end
					out[#out + 1] = string.format("  (… %d more lines; `git show %s %s` for the file)",
						#lines - room, tostring(data.sha):sub(1, 7), name)
					spent = budget
				else
					table.move(lines, 1, #lines, #out + 1, out)
					spent += #lines
				end
			end
		end
		if #files == 0 then
			out[#out + 1] = "no file list — the host omits one for a commit of more than 300 files"
		end
		return table.concat(out, "\n")
	end

	if sub == "pull" then
		local cfg, configErr = remoteConfig()
		if not cfg then
			return fail("git", configErr)
		end
		local remote, remoteErr = remoteTree(cfg)
		if not remote then
			return fail("git", remoteErr)
		end
		local working = Git.walk(game)
		local status = Git.compare(working, remote)
		-- The one guard that matters. A modified path is one where this side and
		-- the remote disagree, which is exactly what pull would overwrite, so it
		-- stops rather than discarding work nobody has committed.
		if #status.modified > 0 and not flags["-f"] then
			return fail("git", string.format("%d local change%s would be overwritten " ..
				"(%s%s) — commit them, or `git pull -f` to discard them",
				#status.modified, #status.modified == 1 and "" or "s",
				status.modified[1], #status.modified > 1 and ", …" or ""))
		end
		local incoming = Git.incoming(working, remote)
		if #incoming == 0 then
			return "Already up to date."
		end

		-- Fetched first, written second. Writing as they arrive would mean
		-- yielding on a request inside an open undo recording, and a half-applied
		-- pull that cannot be undone in one step is the failure worth avoiding.
		local fetched: { { path: string, source: string } } = {}
		for _, path in ipairs(incoming) do
			local text, blobErr = remoteBlob(cfg, remote[path])
			if not text then
				return fail("git", string.format("%s: %s (nothing has been written)", path, tostring(blobErr)))
			end
			fetched[#fetched + 1] = { path = path, source = text }
		end

		local written, failures, undoErr = materialize(self, fetched, "agent: git pull")
		if undoErr then
			return fail("git", undoErr)
		end
		local out: { string } = {
			string.format("%d file%s updated from %s/%s",
				written, written == 1 and "" or "s", cfg.owner, cfg.branch),
		}
		-- Nothing is DELETED by a pull. A script here that the remote does not
		-- have is reported, never removed: this direction is where the data loss
		-- other tools warn about lives, and a report costs one line.
		if #status.added > 0 then
			out[#out + 1] = string.format("%d here but not on the remote, left alone:", #status.added)
			for index, path in ipairs(status.added) do
				if index > 10 then
					out[#out + 1] = string.format("  … %d more", #status.added - 10)
					break
				end
				out[#out + 1] = "  " .. path
			end
		end
		for _, note in ipairs(failures) do
			out[#out + 1] = "failed: " .. note
		end
		return table.concat(out, "\n")
	end

	if sub == "status" or sub == "diff" then
		local cfg, configErr = remoteConfig()
		if not cfg then
			return fail("git", configErr)
		end
		local remote, remoteErr = remoteTree(cfg)
		if not remote then
			return fail("git", remoteErr)
		end
		local working, skipped = Git.walk(game)
		local status = Git.compare(working, remote)

		if sub == "status" then
			return Git.formatStatus(cfg, status, Git.staged(), skipped, MAX_LIST)
		end

		-- diff: a named path, or everything that changed. Deletions are part of
		-- that — a script the remote has and this side does not is a change, and
		-- rendering it as a file removed whole is what git does with one.
		local wanted: { string } = {}
		if operands[2] then
			local path = operands[2]
			if not working[path] and not remote[path] then
				return fail("git", string.format("%q is neither a script here nor a " ..
					"file on the remote — `git status` lists what changed", path))
			end
			wanted[1] = path
		elseif flags["--staged"] or flags["--cached"] then
			-- What commit would send, which is the one diff worth reading before
			-- making one. Both spellings, because git answers to both and picking
			-- a side would make the other look unsupported.
			wanted = Git.staged()
		else
			table.move(status.modified, 1, #status.modified, 1, wanted)
			table.move(status.deleted, 1, #status.deleted, #wanted + 1, wanted)
		end
		if #wanted == 0 then
			return ""
		end
		local out: { string } = {}
		for index, path in ipairs(wanted) do
			if index > 20 then
				out[#out + 1] = string.format("… %d more changed (name one to see it)", #wanted - 20)
				break
			end
			-- A path the remote does not have is a file being ADDED, and it has no
			-- side A to fetch. Guarded rather than assumed: blobUrl formats the sha
			-- with %s, and Luau's string.format raises on nil rather than writing
			-- "nil", so this used to throw outright for `git diff <new script>` —
			-- and would throw on every added path once --staged started including
			-- them.
			local text = ""
			if remote[path] then
				local fetched, blobErr = remoteBlob(cfg, remote[path])
				if not fetched then
					return fail("git", blobErr)
				end
				text = fetched
			end
			-- A deleted path has no side B at all, so it diffs against nothing and
			-- is named /dev/null, which is how git spells "this file is gone". An
			-- added one is the same thing from the other end.
			local mine = working[path]
			local before = remote[path] and splitLines(text) or {}
			local after = mine and splitLines(mine.source) or {}
			local script, diffErr = diffLines(before, after, function(line)
				return diffKey(line, flags)
			end)
			if not script then
				return fail("git", diffErr)
			end
			local body = unified(script, before, after,
				remote[path] and ("a/" .. path) or "/dev/null",
				mine and ("b/" .. path) or "/dev/null", numberOf(values, "-U") or 3)
			if body ~= "" then
				out[#out + 1] = body
			end
		end
		return table.concat(out, "\n")
	end

	return fail("git", string.format("no `git %s` here — this speaks to the host's API, " ..
		"not git's wire protocol, so there is no local history to %s. " ..
		"What exists: %s", sub, sub, GIT_SUB_LIST))
end

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
-- is exempt: `grep "&" f` is a pattern, not a background job, which is what the
-- quoted-position set from tokenize() is for.
--
-- `<` used to be in here. It is a real input redirection now, so the only thing
-- left with no meaning is backgrounding.
local METACHARACTERS: { [string]: boolean } = {
	["&"] = true,
}


-- Commands that can consume a stream. Anything else in a pipeline is a mistake
-- worth naming: `ls | ls` silently ignoring its input is how a wrong answer
-- looks exactly like a right one.
local STDIN_COMMANDS: { [string]: boolean } = {
	cat = true, grep = true, egrep = true, fgrep = true,
	head = true, tail = true, wc = true, sort = true, uniq = true,
	sed = true, tr = true, cut = true,
}

-- One command, already tokenized. `stdin` is a heredoc body or the previous
-- stage's output; `> path` sends this command's output to a script instead.
-- Forward-declared: a `for` loop is a pipeline STAGE, so runCommand has to be
-- able to reach it, and the loop body runs back through runTokens, which is
-- defined below both of them.
local runLoopStage: (any, { string }) -> (string, boolean)

function runCommand(self: any, argv: { string }, stdin: string?): (string, boolean)
	failed, unmatched, missText, trailer = false, false, false, nil
	-- Before takeRedirect, which would otherwise steal a `>` out of the loop's
	-- BODY: `for f in a; do echo $f > out.luau; done` is a redirect per
	-- iteration, not one on the loop.
	if argv[1] == "for" then
		if stdin then
			return fail("bash", "for: a loop does not read input — pipe its output instead"), false
		end
		return runLoopStage(self, argv)
	end
	local args, redirect, append, errRedirect, errAppend, inRedirect = takeRedirect(argv)
	-- `< path` replaces stdin. A pipe on the left loses to it, which is bash's
	-- rule and the only one that can be right: the redirect is the more specific
	-- instruction, and it was written after the pipe.
	--
	-- Read as a FILE — resolve, then its source — rather than through Terminal:cat,
	-- which renders a non-script's properties. `wc -l < /Workspace` counting the
	-- lines of a property dump is a number that means nothing.
	if inRedirect then
		if inRedirect == "" then
			return fail("bash", "`<` needs a path to read from"), false
		end
		local target, resolveErr = self:resolve(inRedirect)
		if not target then
			return fail("bash", resolveErr), false
		end
		local source = getSource(target)
		if not source then
			return fail("bash", "not a script: " .. instancePath(target)), false
		end
		stdin = source
	end
	if #args == 0 then
		if redirect and redirect ~= DEV_NULL then
			return applyRedirect(self, redirect, stdin or "", append), not failed
		end
		return "", true
	end

	-- `command foo args` runs foo with shell functions and aliases bypassed. There
	-- are neither here, so it is exactly `foo args` — stripped rather than handled
	-- inside HANDLERS.command, so that everything below sees the REAL command:
	-- its flag spec and its stdin eligibility. Handling it in the handler would
	-- have meant re-entering dispatch with both already decided against the wrong
	-- name.
	--
	-- A dash after `command` is the -v/-V question instead, which is a command in
	-- its own right and goes to the handler. A loop, not an `if`, because bash
	-- accepts `command command foo` and stopping after one would leave the second
	-- to be read as an operand.
	while args[1] == "command" and args[2] and args[2]:sub(1, 1) ~= "-" do
		table.remove(args, 1)
	end

	local cmd = args[1]
	if stdin and not STDIN_COMMANDS[cmd] then
		return fail("bash", cmd .. " does not read input — pipe into cat, grep, head, tail, wc, sort, uniq, cut, sed or tr"), false
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

	local ok = not (failed or unmatched)
	-- `failed` means the output IS the error message, so a `2>` target is where
	-- that message goes and stdout is left empty — which is what makes
	-- `find /Nope -name x 2>/dev/null` finally quiet, and `cmd 2>err.luau` put the
	-- reason somewhere readable. A command that did not fail has nothing to send:
	-- `2>` is not allowed to eat a real answer.
	if failed and errRedirect then
		if errRedirect ~= DEV_NULL then
			-- Written with `failed` cleared, so the only thing that can set it again
			-- is this write, and a report of "could not save the error" is not
			-- swallowed along with the error it was reporting.
			local message = output
			failed = false
			local written = applyRedirect(self, errRedirect, message, errAppend)
			if failed then
				return written, false
			end
		end
		output = ""
		-- The two flags, set to what is now TRUE of this command rather than left
		-- describing the moment before the redirect.
		--
		-- `failed` means "this errored and its output is the message". After the
		-- message has been sent elsewhere that is no longer so — the output is
		-- empty — and it is the reason runPipeline stops, which exists only to
		-- keep an error from flowing on as data. With nothing to leak there is
		-- nothing to stop for, and bash runs the rest of the pipeline anyway:
		-- `find /Nope 2>/dev/null | wc -l` is 0, not an abandoned pipeline.
		--
		-- `unmatched` carries the false status onward, so `&&` still skips and
		-- `||` still fires. Silencing an error must not make it look like success.
		failed = false
		unmatched = true
	end
	if redirect == DEV_NULL then
		return "", ok        -- ran it, threw the output away
	end
	if redirect then
		-- `failed` is read AGAIN because applyRedirect can set it: a write that
		-- could not land is its own failure, on top of whatever the command said.
		return applyRedirect(self, redirect, output, append), ok and not failed
	end
	return output, ok
end

-- A pipeline: each stage's output becomes the next stage's input. A failing
-- stage stops the pipeline rather than feeding an error message downstream as
-- if it were data.
local function runPipeline(self: any, stages: { { string } }, stdin: string?): (string, boolean)
	local input = stdin
	local output, ok = "", true
	-- Trailers from EVERY stage, not just the last. They are this harness's
	-- stderr, and in bash stderr reaches the terminal from any stage of a
	-- pipeline while only stdout is piped onward. Dropping a non-final stage's
	-- note would be worse than leaving it in the data: `cat big.luau | wc -l`
	-- would answer 1000 with nothing anywhere to say the file has 3182 lines,
	-- so the truncation would become invisible rather than merely mis-counted.
	local notes: { string } = {}
	for index, stage in ipairs(stages) do
		output, ok = runCommand(self, stage, input)
		-- Stops on an ERROR, never on a merely false status. There is no stderr
		-- here, so an error message flowing on would be read as data — but a stage
		-- that found nothing did not error, and bash runs the next stage anyway.
		-- `failed` still holds this stage's state: runCommand clears it on entry
		-- and nothing has run since it returned.
		if failed then
			return output, false
		end
		if trailer then
			notes[#notes + 1] = trailer
		end
		-- A miss's prose is not data, so a downstream stage gets nothing to read,
		-- which is what real grep hands it. Not accumulated the way a trailer is:
		-- "no matches" is grep's exit status spelled out, and bash prints nothing
		-- at all for it — where a cap warning is a real thing that happened.
		if index < #stages and missText then
			output = ""
		end
		input = output
	end
	if #notes > 0 then
		local tail = table.concat(notes, "\n")
		output = if output == "" then tail else output .. "\n" .. tail
	end
	-- The pipeline's status is the LAST stage's, as bash has it.
	return output, ok
end

-- Split tokenized argv into statements joined by `;`, `&&` or `||`, each of
-- which is a list of pipeline stages split on `|`.
local SEPARATORS: { [string]: boolean } = { [";"] = true, ["&&"] = true, ["||"] = true }

type Statement = { joiner: string, stages: { { string } } }

-- `quoted` is by position in `argv`, and the whole reason it is threaded this
-- far is `takeRedirect`. A quoted `>` and an operator `>` are the same STRING by
-- the time a stage is assembled, and telling them apart is not cosmetic:
-- `grep '>' f.luau` used to lose its pattern to the redirect parser and write
-- an empty f.luau — a command that searched for nothing, said nothing, and
-- destroyed the file it was supposed to read.
--
-- Positions shift when argv is cut into stages, so the flag is copied onto each
-- stage as it is built. It rides on the stage array the way `skipped` rides on
-- a result list elsewhere here. Absent (a loop body rebuilt by expandVar) means
-- "nothing known to be quoted", which is exactly the old behaviour rather than
-- a new failure.
local function parseStatements(argv: { string }): { Statement }
	local wasQuoted = (argv :: any).quoted or {}
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

	local i = 1
	while i <= #argv do
		local arg = argv[i]
		local stage = current.stages[#current.stages]
		if arg == "for" and #stage == 0 and not wasQuoted[i] then
			-- A loop is ONE stage, taken whole. It used to be claimed before the
			-- split instead, by a parser that only looked at the head of the line,
			-- which is why `cd x; for f in ...` came back as "a `for` loop has to
			-- start the command line" — the `;` had already cut the loop into four
			-- unrunnable pieces. Depth-counted so a nested loop takes its own `done`.
			local depth = 0
			while i <= #argv do
				local token = argv[i]
				stage[#stage + 1] = token
				;(stage :: any).quoted = (stage :: any).quoted or {}
				;(stage :: any).quoted[#stage] = wasQuoted[i] or nil
				-- Quoted, these are DATA: `echo 'done'` in a body must not close
				-- the loop the way a bare `done` does. parseLoop applies the same
				-- rule, and the two have to agree about where the stage ends, or
				-- the body it re-parses is not the one claimed here.
				if token == "for" and not wasQuoted[i] then
					depth += 1
				elseif token == "done" and not wasQuoted[i] then
					depth -= 1
					if depth == 0 then
						break
					end
				end
				i += 1
			end
		-- Quoted or backslashed, a separator is DATA. This read the token text
		-- alone, so `echo ';'` and `echo '|'` were cut into pieces at the very
		-- character they were quoted to protect, and `find ... -exec cat {} \;`
		-- lost everything after the `\;` to a second statement that began with a
		-- pipe. takeRedirect learned this in §3.10; parseStatements did not, and
		-- it is the same set riding on the same argv.
		elseif SEPARATORS[arg] and not wasQuoted[i] then
			flush()
			current = { joiner = arg, stages = { {} } }
		elseif arg == "|" and not wasQuoted[i] then
			current.stages[#current.stages + 1] = {}
		else
			stage[#stage + 1] = arg
			;(stage :: any).quoted = (stage :: any).quoted or {}
			;(stage :: any).quoted[#stage] = wasQuoted[i] or nil
		end
		i += 1
	end
	flush()
	return statements
end

-- Run a statement list. `lastOk` seeds the `&&`/`||` chain, which matters when
-- something ran before these statements did — see the loop below, where `done &&
-- echo ok` has to know whether the loop failed.
local function runStatements(self: any, statements: { Statement },
	stdin: string?, lastOk: boolean): (string, boolean)
	local outputs: { string } = {}
	-- Whether the statement just run produced nothing but a miss's prose. Read by
	-- the `||` branch below, and nowhere else.
	local lastWasProse = false
	for index, statement in ipairs(statements) do
		local skip = (statement.joiner == "&&" and not lastOk)
			or (statement.joiner == "||" and lastOk)
		if not skip then
			-- `grep X f || echo absent` is the idiomatic "is this missing?", and in
			-- bash it prints exactly `absent`: grep's miss is an exit status, not
			-- text. Here the miss carries prose, because a false status is
			-- invisible to whoever is reading — but once the `||` branch actually
			-- FIRES, that prose has been superseded by the fallback it triggered,
			-- and printing `no matches` above `absent` is saying the same thing
			-- twice in two vocabularies.
			--
			-- Only prose is dropped. A statement that produced real data and a
			-- false status — `grep -c X f` returning "0" — keeps it, which is the
			-- whole reason miss() and a bare `unmatched` are different things.
			if statement.joiner == "||" and lastWasProse then
				outputs[#outputs] = nil
			end
			-- `! pipeline` inverts the STATUS and nothing else, which is bash's
			-- own reading of it. Newly useful rather than newly possible: while a
			-- miss reported no status there was nothing worth inverting, and now
			-- `! grep -q X f && echo absent` is the natural way to ask.
			--
			-- The stage list is cloned rather than edited, so the parsed statement
			-- is left as it was written.
			local stages = statement.stages
			local negate = stages[1] ~= nil and stages[1][1] == "!"
			if negate then
				stages = table.clone(stages)
				stages[1] = table.move(stages[1], 2, #stages[1], 1, {})
				if #stages[1] == 0 then
					table.remove(stages, 1)
				end
				if #stages == 0 then
					return fail("bash", "`!` inverts a command's status, so it needs one"), false
				end
			end
			-- A heredoc body belongs to the last statement, the way a shell
			-- attaches it to the command it followed.
			local output, ok = runPipeline(self, stages,
				index == #statements and stdin or nil)
			lastOk = if negate then not ok else ok
			if #statements == 1 then
				-- lastOk, not ok: on a lone `! cmd` the inversion is the whole
				-- point, and returning the raw status would drop it.
				return output, lastOk
			end
			-- Concatenated, with nothing announcing which statement produced what.
			-- `$ <command>` used to be printed over each block, on the reasoning
			-- that several outputs need telling apart — but bash prints no such
			-- thing, and the cost was paid on the commonest line there is:
			-- `cd /Workspace && ls` came back as an empty labelled block for the
			-- cd followed by a labelled listing, four lines of ceremony around one
			-- answer, and `echo a; echo b` returned four lines where every shell on
			-- earth returns two.
			--
			-- The label also carried a diagnostic — it re-quoted each token, so an
			-- agent could see that `grep -E 'a|b'` had NOT had its quotes eaten.
			-- That argument does not survive contact with when the label appeared:
			-- only ever with two or more statements, and a single command, which is
			-- where that worry actually arises, was never labelled at all. The
			-- tokenizer cases above pin the same property down permanently, and
			-- requote/label are gone with this.
			--
			-- Empty output contributes nothing, so a statement that printed
			-- nothing leaves no blank line behind.
			if output ~= "" then
				outputs[#outputs + 1] = output
			end
			lastWasProse = missText and output ~= ""
		end
	end
	return table.concat(outputs, "\n"), lastOk
end

-- Loops
--
-- `for NAME in WORDS; do BODY; done`, and only that one. There is no `while`
-- and no `until`: nothing in this shell can change a condition between two
-- iterations, so either would run zero times or forever, and forever is a frozen
-- Studio with no way out. A word list is finite by construction.
--
-- What it buys is the thing that had no spelling before: one command per
-- instance over a set. `head -5 a b c` prints three files, but `sed -i` on each,
-- or a grep whose pattern differs per file, was a separate tool call each time.
type Loop = { name: string, words: { string }, body: { string }, rest: { string } }

local LOOP_SYNTAX = "`for f in *.luau; do head -5 $f; done`"

-- nil, nil means "not a loop"; nil with a message means it is one and it is
-- malformed. Silently falling through on a malformed loop would run `for` as a
-- command and report an unknown one, which points at the wrong thing.
local function parseLoop(argv: { string }): (Loop?, string?)
	-- Which positions came out of quotes, tagged on by parseStatements. EVERY
	-- structural token below — `;`, `in`, `do`, `done`, `for` — is checked
	-- against it, because a quoted one is an argument rather than syntax.
	--
	-- takeRedirect reads this set and so does parseStatements. parseLoop was the
	-- one parser that did not, and it is the one that cuts up a loop BODY, so
	-- the omission surfaced as `for d in x; do find "$d" -exec stat {} \; ; done`
	-- reporting that -exec had no terminator: the `\;` it was handed had already
	-- been read as the end of the command. The body is rebuilt below, so the map
	-- has to be rebuilt with it or the information is gone by the time it counts.
	local wasQuoted = (argv :: any).quoted or {}
	local function bareWord(at: number, word: string): boolean
		return argv[at] == word and not wasQuoted[at]
	end

	-- Leading `;` tokens are skipped first. A body written on its own line starts
	-- with the one tokenize made from the newline, and a NESTED loop is exactly
	-- that shape: without this, the inner loop of
	--     for a in 1 2; do
	--       for b in x y; do ... ; done
	--     done
	-- is not recognised as a loop at all, and `for` comes back as an unknown
	-- command with the whole command list printed beside it.
	local i = 1
	while bareWord(i, ";") do
		i += 1
	end
	if not bareWord(i, "for") then
		return nil, nil
	end
	local name = argv[i + 1]
	if not name or not name:match("^[%a_][%w_]*$") then
		return nil, string.format("for: %q is not a variable name — %s",
			tostring(name), LOOP_SYNTAX)
	end
	if not bareWord(i + 2, "in") then
		-- bash also has `for f; do`, which iterates the positional parameters.
		-- There are none here, so it can only ever be a typo for the `in` form.
		return nil, "for: expected `in` after the variable — " .. LOOP_SYNTAX
	end

	local words: { string } = {}
	i += 3
	while i <= #argv and not bareWord(i, ";") and not bareWord(i, "do") do
		words[#words + 1] = argv[i]
		i += 1
	end
	-- `; do`, or `do` on the next line, which tokenize has already turned into a
	-- `;`. Several in a row is a blank line between them.
	while bareWord(i, ";") do
		i += 1
	end
	if not bareWord(i, "do") then
		return nil, "for: expected `do` after the word list — " .. LOOP_SYNTAX
	end
	i += 1

	-- Depth-counted so a loop inside a loop takes its own `done` rather than the
	-- outer one's. Nesting costs three lines here and mis-parses silently
	-- without them: the inner body would become the outer's trailing statements.
	local body: { string } = {}
	local bodyQuoted: { [number]: boolean } = {}
	local depth = 1
	while i <= #argv do
		local token = argv[i]
		if token == "for" and not wasQuoted[i] then
			depth += 1
		elseif token == "done" and not wasQuoted[i] then
			depth -= 1
			if depth == 0 then
				i += 1
				break
			end
		end
		body[#body + 1] = token
		-- Re-keyed to the body's OWN positions: the map on `argv` is indexed by
		-- the stage's, and the body starts partway into it.
		bodyQuoted[#body] = wasQuoted[i] or nil
		i += 1
	end
	if depth ~= 0 then
		return nil, "for: missing `done` — " .. LOOP_SYNTAX
	end
	;(body :: any).quoted = bodyQuoted

	local rest: { string } = {}
	local restQuoted: { [number]: boolean } = {}
	table.move(argv, i, #argv, 1, rest)
	-- What follows `done`. takeRedirect reads the same map to tell a redirect
	-- from a quoted `>`.
	for at = i, #argv do
		restQuoted[at - i + 1] = wasQuoted[at] or nil
	end
	;(rest :: any).quoted = restQuoted
	return { name = name, words = words, body = body, rest = rest }, nil
end

-- $NAME and ${NAME} in the body tokens, replaced per iteration.
--
-- AFTER tokenizing, not before, so a word containing a space stays ONE argument.
-- bash re-splits an expanded variable and needs "$f" to stop it; here a path
-- with a space in it simply survives, which is the behaviour every caller wanted
-- from the quotes anyway.
--
-- The frontier is what keeps `$f` out of `$file`: it requires the character
-- after the name to be a non-word one, and end-of-token counts.
local function expandVar(tokens: { string }, name: string, value: string): { string }
	-- A `%` in the value is a capture reference in a gsub replacement, so a path
	-- containing one would corrupt the substitution or throw.
	local replacement = value:gsub("%%", "%%%%")
	local braced = "%${" .. name .. "}"
	local bare = "%$" .. name .. "%f[^%w_]"
	local out: { string } = {}
	for index, token in ipairs(tokens) do
		out[index] = (token:gsub(braced, replacement):gsub(bare, replacement))
	end
	-- Substitution is one token in, one token out, so the quoted map transfers
	-- position for position. Dropping it here was the other half of the `\;`
	-- bug: parseLoop could hand over a perfectly good map and this would rebuild
	-- the body without it, one call before parseStatements went looking.
	;(out :: any).quoted = (tokens :: any).quoted
	return out
end

-- Forward-declared: a loop body is run through the same entry point that
-- detects a loop, which is what makes nesting work without a second parser.
local runTokens: (any, { string }, string?, boolean) -> (string, boolean)

local function runLoop(self: any, loop: Loop, lastOk: boolean): (string, boolean)
	-- Globbed, because `for f in *.luau` is the whole reason to have this.
	local words = expandGlobs(self, loop.words)
	local outputs: { string } = {}
	local ok = lastOk
	for _, word in ipairs(words) do
		local output
		output, ok = runTokens(self, expandVar(loop.body, loop.name, word), nil, true)
		if output ~= "" then
			outputs[#outputs + 1] = output
		end
	end
	-- Iterations run together, exactly as bash does, and NOT under a per-iteration
	-- header: injecting one would corrupt `done | wc -l` and every other pipe.
	-- The commands that need attribution already carry it — `head` prints
	-- `==> path <==` per file, `grep` and `wc` name theirs — so a header here
	-- would be a second, disagreeing one.
	--
	-- bash keeps going after a failing iteration, and so does this: covering the
	-- list is the point, and one missing instance must not silently drop the rest.
	return table.concat(outputs, "\n"), ok
end

-- One loop, as a pipeline stage. `done | wc -l`, `done && echo ok` and
-- `cd x; for ...` all fall out of that: the statement and pipeline machinery
-- already knows what to do with a stage, and each of those shapes used to need
-- its own branch up here, or was refused outright.
function runLoopStage(self: any, argv: { string }): (string, boolean)
	local loop, loopErr = parseLoop(argv)
	if not loop then
		return fail("bash", loopErr or ("for: " .. LOOP_SYNTAX)), false
	end
	-- parseStatements ends the stage at `done`, so anything still in `rest` was
	-- written between `done` and the next separator. A redirect there belongs to
	-- the loop as a whole, which is why it is taken HERE rather than in
	-- runCommand, where it would have reached into the body.
	local rest, redirect, append = takeRedirect(loop.rest)
	if #rest > 0 then
		return fail("bash", "for: unexpected " .. rest[1] .. " after `done`"), false
	end
	local output, ok = runLoop(self, loop, true)
	if redirect == DEV_NULL then
		return "", ok
	end
	if redirect then
		-- Cleared first: `failed` has been reset and set again by every command the
		-- body ran, so the only way to hear about a failing write is to ask about
		-- this one alone.
		failed = false
		local written = applyRedirect(self, redirect, output, append)
		return written, ok and not failed
	end
	return output, ok
end

function runTokens(self: any, argv: { string }, stdin: string?,
	lastOk: boolean): (string, boolean)
	return runStatements(self, parseStatements(argv), stdin, lastOk)
end

-- Forward-declared: `$(...)` runs a whole line of its own.
local runLine: (any, string?, number) -> (string, boolean)

-- The closing `)` of a `$(`, skipping quoted text and nested parens. A plain
-- paren count is not enough, and the command that made this necessary is the one
-- that reported the bug: `$(grep -rl "feintWait(" Weps)` carries an unbalanced
-- `(` INSIDE quotes, and counting it reads the whole rest of the line as open.
local function takeSubstitution(line: string, start: number): (string?, number)
	local depth = 1
	local quote: string? = nil
	local i = start
	while i <= #line do
		local c = line:sub(i, i)
		if c == "\\" and quote ~= "'" then
			i += 2
			continue
		end
		if quote then
			if c == quote then
				quote = nil
			end
		elseif c == "'" or c == '"' then
			quote = c
		elseif c == "(" then
			depth += 1
		elseif c == ")" then
			depth -= 1
			if depth == 0 then
				return line:sub(start, i - 1), i + 1
			end
		end
		i += 1
	end
	return nil, 0
end

-- Characters that must not arrive from a substitution, because splicing happens
-- on the TEXT of the line and tokenize would read them as syntax rather than as
-- part of a name. bash splices post-parse and has no such problem; refusing is
-- the honest version of the difference, and the alternative is an instance whose
-- name contains a `;` quietly becoming two commands.
local UNQUOTED_RISK = "[;|&'\"\\]"
local QUOTED_RISK = "[\"\\]"

-- `$(...)`: run the inner line and splice its output in where it stood.
--
-- On the RAW line, before tokenize, which is where bash does it too — the result
-- has to be re-split into words, and the whole reason to have it is
-- `for f in $(grep -rl Foo)`, one command producing the list the next consumes.
-- Without it that line did not fail: it iterated ONCE, over the literal text
-- `$(grep`, which is the silent kind of wrong.
--
-- Quoting is bash's. Single quotes suppress it; double quotes do not, and inside
-- them the output is spliced whole, so `"$(...)"` stays one word — outside,
-- whitespace collapses to single spaces so tokenize word-splits it instead of
-- reading each output LINE as a new command.
--
-- ponytail: no `${VAR}`, no arithmetic, no backticks, and no expansion inside a
-- heredoc body, which is lifted out before this runs and is meant to be literal
-- text. Ceiling: MAX_SUBSTITUTION_DEPTH levels of shell-in-a-string; `run` is
-- the upgrade path past it.
local MAX_SUBSTITUTION_DEPTH = 4

-- The variables a `for` on THIS line binds.
--
-- `$(...)` is spliced on the raw text, before any loop has run, so a
-- substitution mentioning one of these is reading a name that has no value yet.
-- bash defers a body's substitutions to each iteration; this shell cannot,
-- because splicing happens pre-tokenize and the result has to survive being
-- re-split into words.
--
-- What made this worth a refusal is that the old behaviour was not a failure.
-- The name stayed LITERAL, the inner command ran against the two characters
-- `$m`, and it answered:
--     for m in Xyzzy Plugh; do echo "$(grep -rlw $m / | grep -c .)"; done
-- printed 0 for every module in the list, because grep searched for the string
-- `$m` and honestly found none. That reads as a finding — "no requirers" — and
-- it is not one. A wrong answer that looks like data is worse than an error.
--
-- Some spellings survived by accident: `$(echo $m)` returns the literal `$m`,
-- which expandVar then substitutes on the way past, so it appeared to work.
-- `$(basename $f)` appeared to work too, and quietly stopped the moment a value
-- had a slash in it. Those are not worth preserving.
local function loopNames(line: string): { [string]: boolean }
	-- Quoted text is DATA, the same rule the scanner below runs on: `echo 'for f
	-- in x'` binds nothing, and reading the raw line instead invented an `f` that
	-- then refused a legitimate `$(wc -l $f)` later on the same line. Escapes go
	-- first so a backslashed quote cannot open a span, and each span becomes a
	-- SPACE rather than vanishing, so its neighbours cannot close up into a `for`
	-- nobody wrote.
	local bare = line:gsub("\\.", "  "):gsub("'[^']*'", " "):gsub('"[^"]*"', " ")
	local names: { [string]: boolean } = {}
	for name in bare:gmatch("%f[%w_]for%s+([%a_][%w_]*)%s+in%f[^%w_]") do
		names[name] = true
	end
	return names
end

local function expandSubstitutions(self: any, line: string, depth: number): (string?, string?)
	if not line:find("$(", 1, true) then
		return line, nil
	end
	if depth >= MAX_SUBSTITUTION_DEPTH then
		return nil, string.format("`$(...)` nested more than %d deep", MAX_SUBSTITUTION_DEPTH)
	end
	local bound = loopNames(line)

	local out: { string } = {}
	local quote: string? = nil
	local i = 1
	while i <= #line do
		local c = line:sub(i, i)
		if c == "\\" and quote ~= "'" then
			out[#out + 1] = line:sub(i, i + 1)
			i += 2
		elseif quote ~= "'" and c == "$" and line:sub(i + 1, i + 1) == "(" then
			local inner, after = takeSubstitution(line, i + 2)
			if not inner then
				return nil, "unclosed `$(`"
			end
			-- Read before the loop that would define it: see loopNames above.
			for name in bound do
				local reads = inner:match("%$" .. name .. "%f[^%w_]") ~= nil
					or inner:find("${" .. name .. "}", 1, true) ~= nil
				if reads then
					return nil, string.format(
						"`$(%s)` reads $%s, and the `for` on this line has not bound it " ..
						"yet — `$(...)` is spliced in before the loop runs, so the inner " ..
						"command would see the literal text `$%s` and answer about that. " ..
						"Put the substitution's command in the loop body on its own, or " ..
						"use `run` where a variable is a variable.", inner, name, name)
				end
			end
			local text = runLine(self, inner, depth + 1)
			-- ERRORED, not merely false. Splicing a refusal in as words is how `for
			-- f in $(grep ...)` would come to iterate over the words of an error
			-- message — but a grep that found nothing did not refuse, and bash
			-- iterates zero times there rather than aborting the line. Reading the
			-- status instead would make every empty search a hard failure.
			--
			-- `failed` is the last command inside the substitution, which is the
			-- one whose status bash would take.
			if failed then
				return nil, string.format("`$(%s)` failed — %s", inner, text)
			end
			local risk = quote == nil and UNQUOTED_RISK or QUOTED_RISK
			if text:find(risk) then
				return nil, string.format("`$(%s)` produced text containing shell " ..
					"punctuation, which cannot be spliced into a command line — " ..
					"narrow it, or run the two commands separately", inner)
			end
			if quote == nil then
				text = text:gsub("%s+", " "):match("^%s*(.-)%s*$") :: string
			end
			out[#out + 1] = text
			i = after
		elseif quote then
			if c == quote then
				quote = nil
			end
			out[#out + 1] = c
			i += 1
		elseif c == "'" or c == '"' then
			quote = c
			out[#out + 1] = c
			i += 1
		else
			out[#out + 1] = c
			i += 1
		end
	end
	return table.concat(out), nil
end

-- Run a `bash` line. Split out from dispatch so the tokenizer and the command
-- table can be tested without going through tool_use plumbing.
--
-- /sh and the bash tool are the same call. There used to be a `readOnly` flag
-- that only /sh passed, refusing every command that mutates — on the reasoning
-- that a write should arrive through Claude carrying an undo recording. The
-- second half was never true: withUndo lives in the handlers, so a write from
-- either caller was recorded identically, and what the flag actually bought was
-- that changes stayed in the transcript. That is not worth taking the Delete key
-- off the person who owns the place, and Studio hands them one anyway.
function Shell.run(self: any, line: string?): string
	local output = runLine(self, line, 0)
	return output
end

-- The body of Shell.run, plus the recursion depth `$(...)` needs, and the exit
-- status it needs to refuse splicing the text of a failure.
function runLine(self: any, line: string?, depth: number): (string, boolean)
	local commandLine, stdin, heredocErr = extractHeredoc(line or "")
	if heredocErr then
		return "bash: " .. heredocErr, false
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

	local expanded, subErr = expandSubstitutions(self, commandLine, depth)
	if not expanded then
		return "bash: " .. tostring(subErr), false
	end

	local argv, tokenErr, quoted = tokenize(expanded)
	if not argv then
		return "bash: " .. tostring(tokenErr), false
	end
	for index, arg in ipairs(argv) do
		if METACHARACTERS[arg] and not quoted[index] then
			return string.format("bash: %s is not supported — nothing here runs in the " ..
				"background, and there is no job table to put it in. `|` pipes, " ..
				"`;` `&&` `||` chain, `>` writes and `<` reads.", arg), false
		end
	end

	-- Carried on the array rather than as a parameter, so it survives runTokens
	-- and runStatements without either of them having to know about it, and so a
	-- loop body rebuilt by expandVar simply arrives without one. parseStatements
	-- reads it off here and copies it per stage.
	;(argv :: any).quoted = quoted
	return runTokens(self, argv, stdin, true)
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
		-- A redirection operator delimits a word whether or not it is glued to
		-- one. All four spellings below are the same command in bash; here the
		-- two glued ones used to tokenize as ordinary words, so `echo hi>f.luau`
		-- printed `hi>f.luau` and wrote nothing at all.
		{ line = "echo hi>f.luau", want = { "echo", "hi", ">", "f.luau" } },
		{ line = "echo hi> f.luau", want = { "echo", "hi", ">", "f.luau" } },
		{ line = "echo hi >f.luau", want = { "echo", "hi", ">", "f.luau" } },
		{ line = "echo a>>b", want = { "echo", "a", ">>", "b" } },
		-- ...but a bare 1 or 2 in front of the arrow belongs to the OPERATOR.
		-- Split off as its own word, `find x 2>/dev/null` would search for an
		-- instance named "2" and send the real output to the bit bucket.
		{ line = "find x 2>/dev/null", want = { "find", "x", "2>", "/dev/null" } },
		{ line = "echo 1>out.luau", want = { "echo", "1>", "out.luau" } },
		-- A QUOTED digit is data, not a stream number.
		{ line = 'echo "2">f.luau', want = { "echo", "2", ">", "f.luau" } },
		-- `<` delimits a word on the same rule. It was refused outright before,
		-- so `wc -l < f` — the reflexive spelling — failed the whole line.
		{ line = "wc -l < f.luau", want = { "wc", "-l", "<", "f.luau" } },
		{ line = "wc -l <f.luau", want = { "wc", "-l", "<", "f.luau" } },
		{ line = "sort <a.luau >b.luau", want = { "sort", "<", "a.luau", ">", "b.luau" } },
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
	-- A Name may contain "/", the path separator: mesh imports produce
	-- "Meshes/Anime_Girl" by default. instancePath emits it raw, and `ls -R`
	-- walks by re-resolving the paths it prints, so one such part used to abort
	-- the entire listing with `no child named "Meshes"` — a fragment of its own
	-- name. Resolving one is the fix; a real two-level path of the same spelling
	-- still winning is what makes the fix safe to have made.
	local sliced = Instance.new("Folder")
	sliced.Name = "Meshes/Anime_Girl"
	sliced.Parent = nested
	if Fs.resolve(fixture, "nested/Meshes/Anime_Girl") ~= sliced then
		return false, "resolve could not reach a child whose Name contains a slash"
	end
	local realFolder = Instance.new("Folder")
	realFolder.Name = "Meshes"
	realFolder.Parent = nested
	local realLeaf = Instance.new("Folder")
	realLeaf.Name = "Anime_Girl"
	realLeaf.Parent = realFolder
	if Fs.resolve(fixture, "nested/Meshes/Anime_Girl") ~= realLeaf then
		return false, "the slash fallback shadowed a real two-level path"
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
	-- ...and under `exact`, which is what `find -name` uses, a wildcard-free
	-- pattern is the WHOLE name. The loose form over-reports, and its extra hits
	-- look exactly like real ones, which is why the two forms exist separately.
	for _, case in ipairs({
		{ pattern = "Handler", name = "DamageHandler", want = false },
		{ pattern = "Main", name = "mainframe", want = false },
		{ pattern = "Main", name = "Remainder", want = false },
		{ pattern = "Main", name = "Main", want = true },
		{ pattern = "*.luau", name = "Main.luau", want = true },
		{ pattern = "Main*", name = "MainMenu", want = true },
		-- caseSensitive is the -name / -iname difference, and the only one.
		{ pattern = "main", name = "Main", want = true },
		{ pattern = "main", name = "Main", sensitive = true, want = false },
		{ pattern = "Main", name = "Main", sensitive = true, want = true },
		}) do
		local matches = nameMatcher(case.pattern,
			{ exact = true, caseSensitive = case.sensitive })
		if matches(case.name) ~= case.want then
			return false, string.format(
				"nameMatcher(%q, exact, sensitive=%s)(%q) should be %s",
				case.pattern, tostring(case.sensitive == true), case.name, tostring(case.want))
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
	-- ...and the root is exempt from the cap entirely, because a service is
	-- reachable-or-not, not merely interesting. Asserted against `game` itself
	-- rather than a fixture: this is the one listing whose completeness matters.
	-- `-a` is the complete form: plain `ls /` collapses the EMPTY services, which
	-- Studio instantiates by the hundred and none of which has a subtree behind
	-- it. Both halves are pinned, because each fails in its own direction — the
	-- cap coming back would silently drop Workspace, and the collapse reaching a
	-- service with children would hide a whole tree.
	local allRows = #splitLines(Shell.run(probe, "ls -a /"))
	if allRows ~= #game:GetChildren() then
		return false, string.format("ls -a / listed %d of %d services — the root must never be capped",
			allRows, #game:GetChildren())
	end
	local occupied = 0
	for _, service in ipairs(game:GetChildren()) do
		if #service:GetChildren() > 0 then
			occupied += 1
		end
	end
	local rootOut = Shell.run(probe, "ls /")
	-- One trailer line when anything was collapsed, and none when nothing was.
	local wantRows = occupied + (occupied < #game:GetChildren() and 1 or 0)
	if #splitLines(rootOut) ~= wantRows then
		return false, string.format(
			"ls / emitted %d lines, want %d (%d of %d services have children):\n%s",
			#splitLines(rootOut), wantRows, occupied, #game:GetChildren(), rootOut)
	end
	if occupied < #game:GetChildren() and not rootOut:match("empty services not shown") then
		return false, "ls / collapsed the empty services without saying so:\n" .. rootOut
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
	local grepTotal = Shell.run(probe, "grep -hc needle")
	local grepOne = Shell.run(probe, "grep -c needle A")
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
	-- -c answers per file when the search covered more than one, which is the
	-- shape `grep -rc X dir | grep -v ":0"` is written against and the reason a
	-- bare total was wrong. -h forces the total back; one named script counts
	-- bare because it was one input. All three go through the per-file counts,
	-- never through the grouping the header check above pins — that separation is
	-- still what this is here to catch.
	if grepCount ~= "/A:2\n/B:1" then
		return false, string.format("grep -c over a container returned %q, want /A:2 and /B:1",
			grepCount)
	end
	if grepTotal ~= "3" then
		return false, "grep -hc returned " .. grepTotal .. ", want the bare total 3"
	end
	if grepOne ~= "2" then
		return false, "grep -c on one named script returned " .. grepOne .. ", want a bare 2"
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
	-- Delimited columns for cut. Colons rather than tabs so the fixture is
	-- readable here, and an EMPTY middle field on the MIDDLE row, because a plain
	-- split and a whitespace-collapsing one disagree about exactly that and cut
	-- is the one that keeps it.
	--
	-- Three rows, not two, on purpose: with the empty field on the last row the
	-- result ends in an empty line, and a trailing empty line is exactly what the
	-- no-trailing-newline convention cannot represent (see FIDELITY.md §3.6). The
	-- assertion would then be pinning that ambiguity rather than cut's behaviour.
	local columns = Instance.new("ModuleScript")
	columns.Name = "Columns"
	columns.Source = "a:b:c\nd::f\ng:h:i\n"
	columns.Parent = textFixture
	-- A line built to make a nested quantifier blow up: every prefix of the a's
	-- can be split between the inner and outer loop, and the final `!` means no
	-- arrangement ever satisfies `$`. Unbounded, this is a frozen Studio.
	local runaway = Instance.new("ModuleScript")
	runaway.Name = "Runaway"
	runaway.Source = string.rep("a", 40) .. "!\n"
	runaway.Parent = textFixture
	probe.cwd = textFixture

	local checks: { { line: string, want: string, why: string } } = {
		-- seq exists to feed `for i in $(seq 1 20)`, so what has to hold is that a
		-- negative operand survives the FLAG parser: `-1` is a step, not a flag,
		-- and `-0.5` used to be taken apart into -0, -. and -5 before the numeric
		-- guard in partition learned about decimal points.
		{ line = "seq 5", want = "1\n2\n3\n4\n5", why = "one operand is the LAST" },
		{ line = "seq 5 -1 1", want = "5\n4\n3\n2\n1", why = "a negative step is an operand" },
		{ line = "seq 2 -0.5 1", want = "2.0\n1.5\n1.0", why = "a negative decimal step" },
		{ line = "seq -w -s , 8 10", want = "08,09,10", why = "seq -w pads, -s joins" },
		{ line = "seq 5 1", want = "", why = "a step pointing away from the end is empty" },
		-- sort -n reads a LEADING number. Lua's tonumber wants the whole string
		-- to be one, so every "12 something" line — which is what du, wc and
		-- `grep -c` print, and most of what gets piped here — measured as 0 and
		-- fell through to the lexical tiebreak. GNU puts the prose first at 0,
		-- then 3, then 12; the broken reading put "12 b" before "3 a".
		{ line = 'echo -e "12 b\\n3 a\\nbanana" | sort -n', want = "banana\n3 a\n12 b",
		  why = "sort -n reads a leading number, not the whole line" },
		-- ...and a plain sort of the same three is still lexical.
		{ line = 'echo -e "12 b\\n3 a\\nbanana" | sort', want = "12 b\n3 a\nbanana",
		  why = "sort without -n is lexical" },
		-- The whole point: one command producing the words the next consumes.
		{ line = "for i in $(seq 1 3); do echo n$i; done", want = "n1\nn2\nn3",
		  why = "seq feeds a counted loop" },
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

		-- Several statements concatenate, exactly as bash does, with nothing
		-- announcing which produced what. The quoted `|` still reaches grep as one
		-- token — that is the tokenizer's job and the cases above pin it down.
		{ line = "echo one; grep -c -E 'alpha|beta' Sample.luau",
		  want = "one\n2",
		  why = "the echo re-quotes what tokenize took apart" },

		-- cat display flags.
		{ line = "cat -n Cased.luau", want = "     1\tHumanoid\n     2\thumanoid",
		  why = "cat -n numbers lines" },
		{ line = "cat -E Cased.luau", want = "Humanoid$\nhumanoid$", why = "cat -E marks line ends" },
		-- cat CONCATENATES. It used to print head's `==> path <==` banner over each
		-- file, which no cat does and which `cat a b > merged.luau` wrote into the
		-- script. The banner still exists on head/tail, where it belongs.
		{ line = "cat Cased.luau Nums.luau", want = "Humanoid\nhumanoid\n10\n2\n30\n",
		  why = "cat concatenates with no header between files" },

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
		-- Every operand, not just the first. sed read operands[1] and dropped the
		-- rest, so `sed -i` over a list of files rewrote one, said nothing about
		-- the others, and returned a success message.
		{ line = "sed -n '1p' Sample.luau Cased.luau",
		  want = "==> /Sample <==\nalpha\n\n==> /Cased <==\nHumanoid",
		  why = "sed reads every operand, with headers" },
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
		{ line = "find . -name '*.luau' | wc -l", want = "7",
		  why = "find -name matches the .luau display name" },
		-- `ls` only prints .luau, but resolve accepts `cat Main.lua`, so a filter
		-- that refused .lua had the harness contradicting itself.
		{ line = "find . -name '*.lua' | wc -l", want = "7",
		  why = "find -name matches .lua for the same scripts" },
		{ line = "grep -rl beta . --include=*.lua", want = "/Sample",
		  why = "--include=*.lua filters the same scripts as *.luau" },
		{ line = "grep -rl beta . --exclude=*.lua", want = "no matches",
		  why = "--exclude=*.lua excludes them too" },
		{ line = "find . -name Sample", want = "/Sample  [ModuleScript]",
		  why = "find -name matches the real name" },
		-- -name is a GLOB, so a wildcard-free pattern is the whole name. It used
		-- to be a case-insensitive substring, which quietly returned more than was
		-- asked for, and the extra hits looked exactly like real ones.
		{ line = "find . -name ample", want = "no matches",
		  why = "-name is not a substring search" },
		{ line = "find . -name sample", want = "no matches",
		  why = "-name is case-sensitive" },
		{ line = "find . -iname sample", want = "/Sample  [ModuleScript]",
		  why = "-iname is the case-insensitive one, and now the only one" },
		-- The bare form is this harness's own shorthand and stays forgiving.
		{ line = "find ample", want = "/Sample  [ModuleScript]",
		  why = "`find <pattern>` is still a loose substring search" },

		-- A miss is PROSE, and prose is not data. `no matches` used to flow down
		-- the pipe as if it were a result, so the single most natural way to ask
		-- "how many?" answered 1 for none — a wrong number produced by the message
		-- that exists to be helpful, with nothing in the output to say so.
		{ line = "grep zzznope . | wc -l", want = "0",
		  why = "a miss feeds the next stage nothing, the way real grep does" },
		{ line = "find . -name zzznope | wc -l", want = "0",
		  why = "find's miss is prose too" },
		{ line = "grep zzznope Sample.luau", want = "no matches",
		  why = "...but the last stage still says so, since there is no stderr" },
		-- A fired `||` supersedes the prose that fired it. bash prints exactly
		-- `absent` here — grep's miss is an exit status, not text — and saying
		-- "no matches" above it is the same fact twice in two vocabularies.
		{ line = "grep zzznope Sample.luau || echo absent", want = "absent",
		  why = "a fired || replaces the miss prose that triggered it" },
		-- ...but only PROSE is dropped. A false status carrying real data keeps
		-- it, which is the whole reason miss() and a bare `unmatched` differ.
		{ line = "grep -c zzznope Sample.luau || echo absent", want = "0\nabsent",
		  why = "grep -c's zero is data and survives the fallback" },
		-- The one miss that IS data: -c was asked for a number and 0 is the
		-- number. Suppressing it would break `grep -c X . | sort -n`.
		{ line = "grep -c zzznope Sample.luau | wc -l", want = "1",
		  why = "grep -c's zero is the answer, not a note about it" },
		-- An empty listing is prose for the same reason a miss is. `ls empty | wc -l`
		-- has to answer 0, not 1 for the sentence saying it is empty.
		{ line = "ls Sample.luau | wc -l", want = "0",
		  why = "an empty listing feeds the next stage nothing" },
		{ line = "ls Sample.luau", want = "(empty) /Sample [ModuleScript]",
		  why = "...and still names what it resolved when nothing is downstream" },

		-- A quoted `>` is a one-character pattern. Read as a redirect it took the
		-- path with it, so this searched for nothing and TRUNCATED the file it was
		-- pointed at — a silent wrong answer that also destroyed data.
		{ line = "grep '>' Sample.luau", want = "no matches",
		  why = "a quoted > is a pattern, not a redirection" },

		-- `2>` used to be recognised and thrown away, so the most reflexive way
		-- there is to quiet a probe did nothing and the noise stayed in the
		-- output. `failed` already means "the output IS the error message", so
		-- there was always somewhere to send it.
		{ line = "cat nosuchscript.luau 2>/dev/null", want = "",
		  why = "2>/dev/null discards a failure's message" },

		-- `< path` replaces stdin. It used to be refused by the metacharacter
		-- gate, which failed the whole line rather than the redirect, so the most
		-- reflexive way to ask "how long is this file" did not work at all.
		{ line = "wc -l < Sample.luau", want = "5", why = "< reads a file as stdin" },
		{ line = "sort < Nums.luau | head -1", want = "10",
		  why = "< composes with a pipe on its right" },
		-- The redirect wins over a pipe feeding the same command, as in bash.
		{ line = "echo zzz | wc -l < Cased.luau", want = "2",
		  why = "< overrides a pipe's stdin" },
		-- A quoted one is a pattern, exactly as with `>`.
		{ line = "grep '<' Sample.luau", want = "no matches",
		  why = "a quoted < is a pattern, not a redirection" },

		-- A BACKSLASHED separator is data too, and it was not: the escape put the
		-- character straight into the word without marking it literal, so the
		-- token that came out was byte-identical to the operator and
		-- parseStatements cut the line at it. `find . -exec cat {} \;` lost
		-- everything after the `\;` to a second statement beginning with a pipe.
		{ line = "echo a \\; b", want = "a ; b",
		  why = "a backslashed ; is a word, not a statement break" },
		{ line = "echo a \\| b", want = "a | b",
		  why = "a backslashed | is a word, not a pipe" },
		-- The quoted forms of the same thing, which parseStatements also cut:
		-- takeRedirect learned about the quoted set in §3.10 and this did not.
		{ line = "echo ';'", want = ";", why = "a quoted ; is an argument" },
		{ line = "echo '|'", want = "|", why = "a quoted | is an argument" },

		-- -exec, once the `\;` survives to reach it. The refusal it replaces said
		-- there was no process to run; there is no process to run in this shell at
		-- all, and every command anyone puts after -exec is one of its own.
		{ line = "find . -name Sample.luau -exec cat {} \\;",
		  want = "alpha\nbeta\ngamma\ndelta\nepsilon",
		  why = "-exec runs a builtin once per result, with {} as the path" },
		{ line = "find . -name Nums.luau -exec sort -n {} +", want = "2\n10\n30",
		  why = "the + form runs once with the paths spliced in" },
		{ line = "find . -name Sample.luau -exec wc -l {} \\; | wc -l", want = "1",
		  why = "-exec output is ordinary stdout and pipes like any other" },

		-- cut. Taking a COLUMN had no spelling here at all before: awk is refused
		-- and its stand-in was `sed -n`, which picks rows, not fields.
		{ line = "cut -d: -f2 Columns.luau", want = "b\n\nh", why = "cut takes a field" },
		{ line = "cut -d: -f1,3 Columns.luau", want = "a:c\nd:f\ng:i",
		  why = "a field list keeps the delimiter between them" },
		{ line = "cut -d: -f3,1 Columns.luau", want = "a:c\nd:f\ng:i",
		  why = "cut never reorders — file order, as everywhere else" },
		{ line = "cut -d: -f2- Columns.luau", want = "b:c\n:f\nh:i",
		  why = "an open range runs to the end of the line" },
		{ line = "cut -c1 Columns.luau", want = "a\nd\ng", why = "-c takes characters" },
		-- An empty field between two delimiters is a real field. This is the whole
		-- reason cut and a whitespace-collapsing split are different tools.
		{ line = "cut -d: -f2 Columns.luau | wc -l", want = "3",
		  why = "an empty field is still a field, and still a line" },
		{ line = "cut -f1 Columns.luau", want = "a:b:c\nd::f\ng:h:i",
		  why = "the default delimiter is TAB, so an untabbed line passes through" },
		{ line = "cut -s -f1 Columns.luau", want = "",
		  why = "-s drops lines with no delimiter instead" },
		-- With the message routed away there is nothing left to leak downstream,
		-- which is the only reason a failing stage stops a pipeline at all.
		{ line = "cat nosuchscript.luau 2>/dev/null | wc -l", want = "0",
		  why = "a silenced failure does not abandon the rest of the pipeline" },

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
		-- Loops. The word list is glob-expanded, $f and ${f} substitute into the
		-- body AFTER tokenizing (so a value with a space stays one argument), and
		-- iterations run together with no header of their own — the commands that
		-- need attribution print their own, and an injected one would corrupt
		-- every pipe the loop feeds.
		{ line = "for f in a b c; do echo $f; done", want = "a\nb\nc",
		  why = "for iterates its word list" },
		{ line = "for f in Sample.luau; do wc -l $f; done", want = "5",
		  why = "the loop variable reaches the body" },
		{ line = "for f in *.luau; do echo $f; done | wc -l", want = "7",
		  why = "the word list is globbed and the loop can feed a pipeline" },
		-- `$ff` is a different variable, not `$f` with an `f` after it, which is
		-- the one substitution mistake that silently mangles a path.
		{ line = "for f in X; do echo ${f}.luau $ff; done", want = "X.luau $ff",
		  why = "${f} substitutes and $ff is left alone" },
		{ line = "for a in 1 2; do for b in x y; do echo $a$b; done; done",
		  want = "1x\n1y\n2x\n2y", why = "loops nest, and the inner done is the inner loop's" },
		-- A loop is a pipeline STAGE now, so it composes like any other command:
		-- after a `;`, after `&&`, feeding a pipe with more statements behind it.
		-- All three used to be refusals, and `cd x; for f in ...` is the one that
		-- reported it — the loop was claimed before statements were split, so the
		-- only place it could appear was the head of the line.
		{ line = "echo one; for f in a b; do echo $f; done",
		  want = "one\na\nb",
		  why = "a loop can follow a `;`" },
		{ line = "for f in a b; do echo $f; done | wc -l; echo tail",
		  want = "2\ntail",
		  why = "a loop feeds a pipeline with statements after it" },
		-- `$(...)`. Without it this line did not fail: the word list was the single
		-- literal token `$(echo`, so the loop ran once over text nobody wrote.
		{ line = "for f in $(echo Sample.luau); do wc -l $f; done", want = "5",
		  why = "$(...) produces the loop's word list" },
		-- A backslashed `;` inside a loop BODY. parseLoop is the parser that cuts
		-- the body out, and it was the one that did not carry the quoted set, so
		-- the `\;` reached -exec already read as a separator and -exec reported a
		-- missing terminator.
		{ line = "for d in .; do find $d -name Sample.luau -exec cat {} \\; ; done",
		  want = "alpha\nbeta\ngamma\ndelta\nepsilon",
		  why = "a backslashed ; survives being cut out as a loop body" },
		-- A QUOTED `for` binds nothing, so the substitution beside it must still
		-- run. loopNames read the raw line and invented an `f` here.
		{ line = "echo 'for f in x'; echo $(echo ok)", want = "for f in x\nok",
		  why = "a quoted for binds no name, so $(...) is not refused" },
		{ line = "echo \"[$(echo a b)]\"", want = "[a b]",
		  why = "a quoted $(...) is spliced whole and stays one word" },
		{ line = "echo '$(echo a)'", want = "$(echo a)",
		  why = "single quotes suppress $(...), as in bash" },

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
			-- -exec RUNS now; what is still an error is leaving off the terminator,
			-- and the message has to name it, since an unterminated -exec would
			-- otherwise swallow the rest of the line as its command.
			{ line = "find / -exec ls", want = "terminating" },
			{ line = "find / -user me", want = "no owner" },
			-- A truncated sequence is the WRONG sequence, and a loop built from one
			-- silently does the wrong number of things, so the cap refuses.
			{ line = "seq 1 5000", want = "5000 values" },
			{ line = "seq 1 0 5", want = "step of zero" },
			{ line = "seq -f %g 5", want = "printf" },
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
			-- A miss is exit 1 and an error is exit 2, and both halves matter:
			-- `||` has to fire after a grep that found nothing, and `&&` must not.
			-- One flag doing both jobs meant `||` never fired at all.
			{ line = "grep zzz Cased.luau || echo fellback", want = "fellback" },
			-- Scoped to the fixture, not `/`: this one actually walks, and a
			-- startup test has no business crawling somebody's whole place.
			{ line = "find . -name zzzznope || echo fellback", want = "fellback" },
			{ line = "[ -f nosuchscript.luau ] || echo fellback", want = "fellback" },
			-- ...and a real match still succeeds, or `&&` is broken for everyone.
			{ line = "grep -q Humanoid Cased.luau && echo ran", want = "ran" },
			{ line = "[ -f Cased.luau ] && echo ran", want = "ran" },
			{ line = "[ 2 -lt 10 ] && echo ran", want = "ran" },
			{ line = "[ x = x ] && echo ran", want = "ran" },
			{ line = "[ ! -f nosuchscript.luau ] && echo ran", want = "ran" },
			-- `!` inverts a pipeline's status. Only worth anything now that a miss
			-- reports one at all.
			{ line = "! grep -q zzz Cased.luau && echo absent", want = "absent" },
			{ line = "! [ -f Cased.luau ] || echo present", want = "present" },
			{ line = "! grep -q Humanoid Cased.luau || echo found", want = "found" },
			-- `2>` sends a failure's message somewhere, and the status has to
			-- survive it: silencing an error must not make it read as success.
			-- Without the second half, `2>/dev/null` would be a way to turn every
			-- failure into a silent pass, which is worse than not supporting it.
			{ line = "cat nosuchscript.luau 2>/dev/null || echo caught", want = "caught" },
			-- Globs reach the commands that were expanding them by hand, and the
			-- ones that take a single path say so rather than silently answering
			-- for whichever match sorted first.
			{ line = "stat -c %n Sample.luau", want = "Sample" },
			{ line = "grep Humanoid *.luau", want = "matches %d+ paths" },
			{ line = "cd -", want = "nothing to go back" },
			{ line = "cd", want = "requires a path" },
			-- A malformed test is an ERROR, not a "no". Otherwise `[ -f ]` with a
			-- forgotten argument silently takes the else branch forever.
			{ line = "[ -f Cased.luau", want = "closing" },
			{ line = "[ -r Cased.luau ]", want = "no permissions" },
			{ line = "[ x -eq y ]", want = "compares numbers" },
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
			-- A malformed loop must name itself. Falling through to the statement
			-- splitter runs `for` as a command, and "unknown command" points at
			-- the word rather than at the missing `done`.
			{ line = "for f in a; do echo $f", want = "missing `done`" },
			{ line = "for f in a done", want = "expected `do`" },
			{ line = "while true; do echo hi; done", want = "zero times or forever" },
			-- A `$(...)` whose command failed must not be spliced. Its output is an
			-- error message, and splicing it is how `for f in $(grep ...)` comes to
			-- iterate over the words of a refusal.
			{ line = "echo $(cat /nope)", want = "failed" },
			{ line = "echo $(echo a", want = "unclosed" },
			-- `$(...)` is spliced before any loop runs, so a substitution reading the
			-- loop variable would search for the literal text `$f` and answer about
			-- that — a wrong answer shaped like a finding.
			{ line = "for f in a b; do echo $(grep -c $f Sample.luau); done",
			  want = "has not bound it yet" },
			{ line = "grep zzz Cased.luau", want = "no matches" },
			-- ...and a `$(...)` that found nothing must NOT be refused. bash
			-- iterates zero times there; refusing turns every empty search into a
			-- dead line, which is what reading the STATUS instead of the error
			-- would have done once a miss started reporting one.
			{ line = "echo $(grep zzz Cased.luau)", want = "^no matches" },
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

	-- find over SEVERAL roots, and depth bounds with no test beside them. Both
	-- were wrong in the way that costs the most: a SHORT answer rather than an
	-- error. `find /A /B -name x` searched only /A and turned /B into a name
	-- test, which then AND-ed itself into the last -o clause and killed that too;
	-- `-maxdepth` alone matched nothing at all. Either one reads as "the
	-- instances are not there", and the next turn acts on that.
	local findFixture = Instance.new("Folder")
	local left = Instance.new("Folder")
	left.Name = "Left"
	left.Parent = findFixture
	local right = Instance.new("Folder")
	right.Name = "Right"
	right.Parent = findFixture
	for _, side in ipairs({ left, right }) do
		local needle = Instance.new("Folder")
		needle.Name = "Needle"
		needle.Parent = side
		local deep = Instance.new("Folder")
		deep.Name = "Deep"
		deep.Parent = needle
	end
	probe.cwd = findFixture
	local findFailure: string? = nil
	repeat
		local function count(line: string): number
			return #splitLines(Shell.run(probe, line))
		end
		-- Bare words are paths once the expression has a test, which is GNU's
		-- rule; `find Handler` with no test is still the native pattern shape.
		if count("find Left Right -name Needle") ~= 2 then
			findFailure = "find over two roots returned: " ..
				Shell.run(probe, "find Left Right -name Needle")
			break
		end
		if count("find Left Right -name Needle -o -name Deep") ~= 4 then
			findFailure = "find with -o over two roots returned: " ..
				Shell.run(probe, "find Left Right -name Needle -o -name Deep")
			break
		end
		-- Overlapping roots name the same instance twice. Listing it twice is a
		-- miscount to read; under -delete it is a second Destroy on a dead one.
		if count("find . Left -name Needle") ~= 2 then
			findFailure = "overlapping roots duplicated a match"
			break
		end
		if count("find Needle") ~= 2 then
			findFailure = "the bare-pattern shape stopped working: " ..
				Shell.run(probe, "find Needle")
			break
		end
		-- Depth bounds on their own. `.` itself is depth 0, so -maxdepth 1 is the
		-- fixture and its two children.
		if count("find . -maxdepth 1") ~= 3 then
			findFailure = "-maxdepth on its own returned: " ..
				Shell.run(probe, "find . -maxdepth 1")
			break
		end
		if count("find . -mindepth 2 -maxdepth 2") ~= 2 then
			findFailure = "-mindepth/-maxdepth on their own did not bound the walk"
			break
		end
	until true
	probe.cwd = savedCwd
	findFixture:Destroy()
	if findFailure then
		return false, findFailure
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
		-- The syntax check, in both directions, because only one of them fails
		-- loudly. A checker wired up wrong tends to return nil for everything,
		-- which passes the valid case silently and ships a write path that can
		-- never report anything: the missing `end` is the half that catches it.
		if Fs.syntaxErrors("local x = 1\nreturn x\n") ~= nil then
			sourceFailure = "valid Luau was reported as a syntax error"
			break
		end
		local broken = Fs.syntaxErrors("local function f()\n\tprint(1)\n")
		if broken == nil or not broken:find("Expected 'end'", 1, true) then
			sourceFailure = "a missing `end` was not caught: " .. tostring(broken)
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

	-- Every command, invoked bare: the one smoke test that covers all of them, and
	-- it catches a handler that throws when its operands are missing. Safe to run:
	-- every command that mutates (rm, mv, cp, set, new, mkdir, touch, ln) needs a
	-- path and bails before touching anything, and the rest just read the cwd.
	--
	-- It does NOT also check for "unknown command" any more. COMMANDS is built by
	-- walking HANDLERS and dispatch looks the name back up in HANDLERS, so that
	-- branch could not fire — and it would not have caught the drift it was named
	-- for, which was a hand-written list too SHORT, not one with a bad entry.
	for _, name in ipairs(COMMANDS) do
		local ok, result = pcall(function()
			return Shell.run(probe, name)
		end)
		if not ok then
			return false, string.format("shell(%q) threw: %s", name, tostring(result))
		end
	end
	if not Shell.run(probe, "chown me /Workspace"):match("no owner") then
		return false, "UNSUPPORTED lookup is not firing"
	end

	-- curl and wget, up to but never past the point where a request would be
	-- made: a startup self-test has no business touching the network. The three
	-- string functions are therefore called directly, since anything that gets
	-- past them goes out on the wire.
	--
	-- Deliberately not checked: the flags that exist only to be refused. Their
	-- `why` text is a literal, and the spec validator below already proves every
	-- entry is reachable and does not contradict a declared flag. One case keeps
	-- the lookup itself honest. Nor is any shared rule checked twice under both
	-- command names — after httpRequest and parseHeaders, that would only be
	-- testing that wget spelled its own flag correctly.
	if not robloxDomain("https://create.roblox.com/docs/llms.txt")
		or not robloxDomain("http://user@WWW.Roblox.com:443/y")
		or robloxDomain("https://notroblox.com/x") then
		return false, "the Roblox-domain rule is wrong"
	end
	if appendQuery("https://h/p", "a=1") ~= "https://h/p?a=1"
		or appendQuery("https://h/p?x=0", "a=1") ~= "https://h/p?x=0&a=1" then
		return false, "curl -G built the wrong query string"
	end
	-- The name wget saves under, which becomes a real script in someone's place.
	-- A path ending in / names a directory: wget writes index.html there, and
	-- refusing is the honest answer when the tree is a DataModel.
	if nameFromUrl("https://h/docs/llms.txt?v=2#top") ~= "llms.txt"
		or nameFromUrl("https://h/a/b/") ~= nil then
		return false, "wget picked the wrong name to save under"
	end
	-- -w, the half of `curl -s -o /dev/null -w "%{http_code}\n"` that is not just
	-- flags. An unknown variable has to be refused rather than expanded to
	-- nothing, or the format prints a number that reads as a measurement.
	local report = expandWriteOut("%{http_code} %{size_download}\\n%%",
		{ http_code = "404", size_download = "12" })
	if report ~= "404 12\n%" then
		return false, "curl -w expanded wrongly: " .. tostring(report)
	end
	local _, wErr = expandWriteOut("%{time_connect}", { http_code = "200" })
	if not wErr or not wErr:find("http_code", 1, true) then
		return false, "curl -w accepted a variable RequestAsync cannot report"
	end
	for line, wanted in pairs({
		["curl create.roblox.com"] = "http:// or https://",
		['curl -H "User-Agent: me" https://example.invalid'] = "locked by Roblox",
		["curl -X PU https://example.invalid"] = "unknown method",
		["curl -X GET -d x https://example.invalid"] = "cannot carry a body",
		["curl -m 0 https://example.invalid"] = "greater than zero",
		["curl -d @/nope https://example.invalid"] = "no child named",
		["curl -v https://example.invalid"] = "no stderr here",
		-- wget's own half: where the body goes, decided before the fetch.
		["wget https://example.invalid"] = "name one with -O",
	}) do
		local out = Shell.run(probe, line)
		if not out:find(wanted, 1, true) then
			return false, string.format("%q wanted %q, got: %s", line, wanted, out)
		end
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

	-- `command -v` on a miss prints NOTHING and fails. Both halves matter: the
	-- form exists to be read as a status by `&&`, and any message added here
	-- would land in the output of every guard that used it.
	if Shell.run(probe, "command -v nosuchthing") ~= "" then
		return false, "command -v is not silent on a miss"
	end
	if Shell.run(probe, "command -v nosuchthing && echo reached"):match("reached") then
		return false, "command -v does not fail on a miss"
	end
	if Shell.run(probe, "command -v grep") ~= "grep" then
		return false, "command -v does not name a builtin"
	end
	-- The strip, from the other side: `command foo` has to BE `foo`, flags and all.
	if Shell.run(probe, "command echo hi") ~= Shell.run(probe, "echo hi") then
		return false, "`command foo` is not the same as `foo`"
	end

	-- Git owns its own checks now, the way Regex and Sed do; what stays here is
	-- the part that belongs to the HANDLER rather than to the module.
	local gitOk, gitErr = Git.selfTest()
	if not gitOk then
		return false, "git: " .. tostring(gitErr)
	end
	-- The token is the one value in this shell that must never reach a tool
	-- result, since a tool result is a transcript and a transcript is stored.
	if Shell.run(probe, "git config"):match("token%s+gh") then
		return false, "git config printed the token instead of whether one is set"
	end
	-- GIT_SUBS is a hand-written list beside a hand-written dispatch, which is
	-- how the old messages came to advertise three subcommands out of eight. A
	-- name with no branch behind it falls through to "no `git X` here", so
	-- walking the list catches the drift the derivation cannot. Each name fails
	-- for its OWN reason here (no remote, no message, no slug) and none of those
	-- is the fallthrough. Skipped without EncodingService, where every subcommand
	-- returns the same one message before reaching its branch.
	if Git.available() then
		for _, sub in ipairs(GIT_SUBS) do
			if Shell.run(probe, "git " .. sub):match("no `git " .. sub .. "` here") then
				return false, "GIT_SUBS lists " .. sub .. ", which no branch answers"
			end
		end
		-- What clone and show read BEFORE they reach the network, so a call with
		-- the argument missing names the shape instead of spending a request to
		-- come back with "not found".
		for _, case in ipairs({
			{ line = "git clone", want = "owner" },
			{ line = "git clone nope", want = "owner" },
			{ line = "git show", want = "sha" },
		}) do
			if not Shell.run(probe, case.line):match(case.want) then
				return false, case.line .. " did not name what it wanted"
			end
		end
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

	-- Tags and attributes are the two pieces of instance metadata with no
	-- property behind them, so nothing else in the shell reads them and nothing
	-- else would notice if either stopped being read.
	local tagFixture = Instance.new("Folder")
	local tagged = Instance.new("ModuleScript")
	tagged.Name = "Tagged"
	tagged.Parent = tagFixture
	local untagged = Instance.new("ModuleScript")
	untagged.Name = "Plain"
	untagged.Parent = tagFixture
	game:GetService("CollectionService"):AddTag(tagged, "SelfTestTag")
	tagged:SetAttribute("Health", 100)
	probe.cwd = tagFixture
	local tagOut = Shell.run(probe, "find . -tag SelfTestTag")
	local statOut = Shell.run(probe, "stat Tagged.luau")
	local plainStat = Shell.run(probe, "stat Plain.luau")
	probe.cwd = savedCwd
	tagFixture:Destroy()
	if not tagOut:match("Tagged") or tagOut:match("Plain") then
		return false, "find -tag did not select by tag: " .. tagOut
	end
	if not statOut:match("Tags: SelfTestTag") then
		return false, "stat did not report tags: " .. statOut
	end
	if not statOut:match("Attributes: Health=100") then
		return false, "stat did not report attributes: " .. statOut
	end
	-- The empty case is omitted, not printed empty, which is the whole reason
	-- these two lines cost nothing on the instances that have neither.
	if plainStat:match("Tags:") or plainStat:match("Attributes:") then
		return false, "stat printed empty tag/attribute lines: " .. plainStat
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
