--!optimize 2
-- Shell.luau — the command line: parsing, composition, and the command table.
--
-- Split from Terminal on the seam that was already there. Terminal knows how to
-- do things to the DataModel — list a container, read a script's source, clone
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

-- Not shell commands at all — they exist as tools, because "create an instance
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

-- =============================================================================
-- Command-line parsing
-- =============================================================================
-- Inside double quotes bash only escapes these four; a backslash before anything
-- else is an ordinary character. Getting that wrong is not cosmetic: `grep -nE
-- "^\t###"` used to arrive as `^t###`, so the search ran against a pattern nobody
-- wrote and came back "no matches" — a still-broken command reading as a
-- verified-absent result, which is the one output there is no way to doubt.
local DOUBLE_QUOTE_ESCAPES: { [string]: boolean } = {
	['"'] = true, ["\\"] = true, ["$"] = true, ["`"] = true,
}

-- Split a shell-ish line into argv, honouring quotes so instance names with
-- spaces survive — `cd "My Model"` is the common case, and a plain split on
-- whitespace gets it wrong on day one.
--
-- ponytail: not a shell. No variables, command substitution or control flow, and
-- no reason to add them — anything that needs those should use `run`. Ceiling:
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
			-- ";" never reaches here — the quote branch above claims it first.
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
			-- ran as the single command `ls /Workspace cat Main.luau` — one
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

-- Render an allowed-flag string for an error message: "nvc" -> "-n -v -c".
local function flagNames(allowed: string): string
	if allowed == "" then
		return "no flags"
	end
	local spaced = allowed:gsub(".", "-%0 ")
	return (spaced:gsub("%s+$", ""))
end

-- Split argv into a flag set and positional operands, so no handler has to
-- re-derive them. Short flags bundle the way they do in bash (-rn is -r -n).
-- A lone "-" and a bare "-20" are operands, not flags: `head -20` means twenty
-- lines, and losing that to the flag set is how `head -20 x` becomes `head x`.
--
-- `allowed` is the flag LETTERS the command accepts. Without it every flag is
-- taken on faith, which is how an unimplemented flag became a silent wrong
-- answer: `grep -A 3 pat f` put -A in the set nobody read, left `3` as a
-- positional, and reported `no child named "3"` — an error naming the argument
-- for the absence of the flag. See FLAGS, where every command declares its own.
local function partition(argv: { string }, allowed: string?): ({ [string]: boolean }, { string }, string?)
	local flags: { [string]: boolean } = {}
	local operands: { string } = {}
	for i = 2, #argv do
		local arg = argv[i]
		if #arg > 1 and arg:sub(1, 1) == "-" and not arg:match("^%-%d+$") then
			if arg:sub(1, 2) == "--" then
				if allowed then
					return flags, operands, string.format("unsupported flag %s — %s takes %s",
						arg, argv[1], flagNames(allowed))
				end
				flags[arg] = true
			else
				-- `head -n20`, `grep -A3`: bash lets a short flag carry its value
				-- glued on. Splitting the digits back out as an operand is what
				-- lets takeCount and grep's context flags find the number, instead
				-- of `-n20` landing as the three flags -n -2 -0 and no count.
				local letters, digits = arg:sub(2):match("^(%a*)(%d*)$")
				if not letters or letters == "" then
					letters, digits = arg:sub(2), ""
				end
				for char in letters:gmatch(".") do
					if allowed and not allowed:find(char, 1, true) then
						return flags, operands, string.format("unsupported flag -%s — %s takes %s",
							char, argv[1], flagNames(allowed))
					end
					flags["-" .. char] = true
				end
				if digits ~= "" then
					operands[#operands + 1] = digits
				end
			end
		else
			operands[#operands + 1] = arg
		end
	end
	return flags, operands, nil
end

-- head/tail/tree all take an optional count. Once partition() has removed the
-- -n / -L flag itself, `head -n 20 x`, `head -20 x`, `head x 20` and `head x`
-- all reduce to the same two operands in some order.
local function takeCount(operands: { string }): (string?, number?)
	local path: string? = nil
	local count: number? = nil
	for _, operand in ipairs(operands) do
		-- `-20` means twenty lines, not minus twenty, so the flag form has to be
		-- checked before tonumber — which would happily hand back a negative and
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
-- the same thing — the distinction that makes them differ in bash doesn't exist.
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
-- `2>` and `&>` aim at a stderr stream that does not exist here — errors come
-- back as ordinary output — so they are dropped. Without that, `2>/dev/null` is
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
	chmod = "instances have no permission bits; use the run tool to change properties",
	chown = "instances have no owner",
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

-- Rojo's suffix convention, which is the one Roblox developers already have in
-- their fingers, and the only way `touch` and `> path` can pick between three
-- script classes without guessing. No suffix means ModuleScript, the safe
-- default: it does nothing until something requires it.
local TOUCH_CLASSES = {
	{ suffix = ".server.luau", class = "Script" },
	{ suffix = ".client.luau", class = "LocalScript" },
}

local function classFor(leaf: string): (string, string)
	for _, entry in ipairs(TOUCH_CLASSES) do
		if #leaf > #entry.suffix and leaf:sub(-#entry.suffix) == entry.suffix then
			return entry.class, leaf:sub(1, -#entry.suffix - 1)
		end
	end
	if leaf:sub(-5) == ".luau" then
		return "ModuleScript", leaf:sub(1, -6)
	end
	return "ModuleScript", leaf
end

-- `> path` on a path that does not exist creates the script, the way a shell
-- creates the file. Without this the most common heredoc there is — writing a
-- new module — would fail on resolve, which is not what the model asked for.
local function ensureScript(self: any, path: string): (Instance?, string?)
	local existing = self:resolve(path)
	if existing then
		return existing, nil
	end
	local parentPath, leaf = splitPath(path)
	local parent, parentErr = self:resolve(parentPath)
	if not parent then
		return nil, parentErr
	end
	local class, name = classFor(leaf)
	return withUndo("Claude: create " .. name, function()
		local inst = Instance.new(class)
		inst.Name = name
		inst.Parent = parent
		return inst
	end)
end

-- `&&` and `||` need to know which returned strings were failures. A flag set
-- at the point of failure is honest about it; sniffing for a "cat: " prefix
-- would misread a script whose own first line happens to look like one.
local failed = false
local function fail(prefix: string, err: any): string
	failed = true
	return prefix .. ": " .. tostring(err)
end

local function applyRedirect(self: any, path: string, content: string, append: boolean): string
	local target, err = ensureScript(self, path)
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

-- One function per command. A table rather than an elseif chain because the
-- list is the thing that grows, and this way the "unknown command" hint and the
-- alias entries below are derived from it instead of maintained alongside it.
local HANDLERS: { [string]: (any, { string }, string?) -> string } = {}

HANDLERS.pwd = function(self)
	return self:pwd()
end

-- whoami — who is running this, and where.
--
-- Marginal on its own, but it is a reflex command, it was answering "unknown
-- command", and the place ids are genuinely worth having: an unpublished place
-- reports 0, which tells the model up front that anything asset- or
-- DataStore-shaped is going to fail for reasons that have nothing to do with
-- its code.
--
-- Deliberately no username lookup. GetNameFromUserIdAsync yields, and handlers
-- run inside the SSE stream callback where yielding stalls parsing mid-buffer.
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
	return table.concat(argv, " ", 2, #argv)
end

HANDLERS.cd = function(self, argv)
	local _, operands = partition(argv)
	if not operands[1] then
		return "cd: requires a path"
	end
	local ok, err = self:cd(operands[1])
	if not ok then
		return fail("cd", err)
	end
	return self:pwd()
end

HANDLERS.ls = function(self, argv)
	local flags, operands = partition(argv)
	local target, glob = splitGlob(operands[1])
	local names, err = self:ls(target, flags["-l"], glob and nameMatcher(glob) or nil)
	if not names then
		return fail("ls", err)
	end
	if #names == 0 then
		-- A bare "(empty)" is indistinguishable from "ls silently failed", which
		-- is what sends an agent off probing with `|| echo "no ls support"`.
		-- Naming what was resolved makes a wrong-instance hit obvious instead:
		-- FindFirstChild("ServerStorage") and GetService("ServerStorage") return
		-- different objects the moment something else in game shares the name.
		local resolved = self:resolve(target)
		local label = resolved
			and string.format("%s [%s]", instancePath(resolved), resolved.ClassName)
			or tostring(target)
		return string.format("(%s) %s", glob and "no matches" or "empty", label)
	end
	-- find and grep stop at a cap; ls did not, so `ls /Workspace` in a place with
	-- a few thousand parts returned every one of them and only `forModel`'s
	-- 100 000-char cut stopped it — by which point the listing is ~25 000 tokens
	-- that every later turn re-sends. Capped HERE rather than in Terminal:ls
	-- because expandGlobs consumes that return value as a list of paths, and a
	-- sentinel row would arrive at cat/head/grep as an operand.
	if #names > MAX_LIST then
		local extra = #names - MAX_LIST
		return string.format("%s\n… %d more (narrow it: `ls %s/A*`, or `ls | grep <name>`)",
			table.concat(names, "\n", 1, MAX_LIST), extra, target or ".")
	end
	return table.concat(names, "\n")
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
		local matched = self:ls(dir, false, nameMatcher(pattern))
		if not matched or #matched == 0 then
			-- Same as bash with nullglob off: an unmatched pattern is passed
			-- through untouched, so the command reports it by name rather than
			-- silently doing nothing.
			out[#out + 1] = operand
		else
			local prefix = (dir and dir ~= "" and dir ~= "/") and (dir .. "/") or (dir == "/" and "/" or "")
			for _, name in ipairs(matched) do
				out[#out + 1] = prefix .. name
			end
		end
	end
	return out
end

HANDLERS.cat = function(self, argv, stdin)
	local _, operands = partition(argv)
	if #operands == 0 and stdin then
		return stdin
	end
	operands = expandGlobs(self, operands)
	if #operands <= 1 then
		local s, err = self:cat(operands[1])
		return s or fail("cat", err)
	end
	-- Real cat concatenates; with several scripts a header is the only way to
	-- tell where one ended.
	local parts: { string } = {}
	for _, operand in ipairs(operands) do
		local s, err = self:cat(operand)
		parts[#parts + 1] = string.format("==> %s <==\n%s", operand, s or ("cat: " .. tostring(err)))
	end
	return table.concat(parts, "\n\n")
end

HANDLERS.stat = function(self, argv)
	local _, operands = partition(argv)
	local s, err = self:stat(operands[1])
	return s or fail("stat", err)
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
-- above it — it would read as a nil global and throw at call time.
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

-- `-c` counts BYTES, not lines. It used to land in the flag set that nobody
-- read, so `head -c 50 f` silently ran as `head f` and returned ten lines —
-- roughly 1500 characters to someone probing a large file specifically to avoid
-- flooding their context. A silent wrong answer on the one command whose whole
-- purpose is to limit output.
local function byteSlice(self: any, cmd: string, argv: { string }, stdin: string?, fromEnd: boolean): string?
	local flags, operands = partition(argv)
	if not flags["-c"] then
		return nil
	end
	local target, count = takeCount(operands)
	if not count then
		return fail(cmd, "-c needs a byte count, as `" .. cmd .. " -c 200 file`")
	end
	local input, inputErr = textInput(self, { target }, stdin)
	if not input then
		return fail(cmd, inputErr)
	end
	return fromEnd and input:sub(-count) or input:sub(1, count)
end

HANDLERS.head = function(self, argv, stdin)
	local bytes = byteSlice(self, "head", argv, stdin, false)
	if bytes then
		return bytes
	end
	local _, operands = partition(argv)
	local target, count = takeCount(operands)
	if stdin and not target then
		local all = splitLines(stdin)
		return table.concat(all, "\n", 1, math.min(count or 10, #all))
	end
	local s, err = self:head(target, count)
	return s or fail("head", err)
end

HANDLERS.tail = function(self, argv, stdin)
	local bytes = byteSlice(self, "tail", argv, stdin, true)
	if bytes then
		return bytes
	end
	local _, operands = partition(argv)
	local target, count = takeCount(operands)
	if stdin and not target then
		local all = splitLines(stdin)
		return table.concat(all, "\n", math.max(1, #all - (count or 10) + 1), #all)
	end
	local s, err = self:tail(target, count)
	return s or fail("tail", err)
end

-- wc returned "238 lines" — prose, not a number, so it composed with nothing and
-- `for f in ...; wc -l < $f` produced a column of sentences. The flags were
-- ignored entirely on a file operand, which is the same shape of bug as head -c.
--
-- Asked for one count, you get one number. Asked for nothing in particular, you
-- get all three labelled, because that is a human reading /sh and there is no
-- second field for them to mistake it for.
HANDLERS.wc = function(self, argv, stdin)
	local flags, operands = partition(argv)
	local input, inputErr = textInput(self, operands, stdin)
	if not input then
		-- Not a script. A container's only size is its children, which is a real
		-- answer to `wc /Workspace` and not one wc can compute from text.
		local target = operands[1] and self:resolve(operands[1])
		if target and not getSource(target) then
			return string.format("%d children", #target:GetChildren())
		end
		return fail("wc", inputErr)
	end

	local lines = #splitLines(input)
	local words = select(2, input:gsub("%S+", ""))
	local counts: { string } = {}
	if flags["-l"] then counts[#counts + 1] = tostring(lines) end
	if flags["-w"] then counts[#counts + 1] = tostring(words) end
	if flags["-c"] then counts[#counts + 1] = tostring(#input) end
	if #counts > 0 then
		return table.concat(counts, " ")
	end
	return string.format("%d lines  %d words  %d bytes", lines, words, #input)
end

HANDLERS.tree = function(self, argv)
	local _, operands = partition(argv)
	local target, depth = takeCount(operands)
	local s, err = self:tree(target, depth)
	return s or fail("tree", err)
end

HANDLERS.du = function(self, argv)
	local _, operands = partition(argv)
	local target, err = self:resolve(operands[1])
	if not target then
		return fail("du", err)
	end
	-- Descendant count is the only "size" this tree has. Sorted heaviest-first,
	-- because the question du answers is always "where is the bulk of this".
	local rows: { { name: string, count: number } } = {}
	local total = 0
	for _, child in ipairs(target:GetChildren()) do
		local count = #child:GetDescendants() + 1
		total += count
		rows[#rows + 1] = { name = child.Name, count = count }
	end
	table.sort(rows, function(a, b)
		return a.count > b.count
	end)
	local lines: { string } = {}
	for _, row in ipairs(rows) do
		lines[#lines + 1] = string.format("%6d  %s", row.count, row.name)
	end
	lines[#lines + 1] = string.format("%6d  total", total)
	return table.concat(lines, "\n")
end

HANDLERS.find = function(self, argv)
	-- Two call shapes reach here: the native `find <pattern> [path]` and the GNU
	-- `find <path> -name <pattern>`. -iname is the same as -name, since matching
	-- is case-insensitive either way.
	local named: string? = nil
	local class: string? = nil
	local depth: number? = nil
	local bare: { string } = {}
	local i = 2
	while i <= #argv do
		local arg = argv[i]
		if arg == "-name" or arg == "-iname" then
			named = argv[i + 1]
			i += 1
		elseif arg == "-type" then
			class = argv[i + 1]
			i += 1
		elseif arg == "-maxdepth" then
			depth = tonumber(argv[i + 1])
			if not depth then
				return "find: -maxdepth needs a number"
			end
			i += 1
		elseif arg:sub(1, 1) == "-" and #arg > 1 then
			-- Refused rather than skipped. Silently ignoring -maxdepth meant
			-- returning the whole subtree to someone who asked for three levels,
			-- with nothing in the output to say so.
			return string.format(
				"find: %s is not supported — try -name, -iname, -type or -maxdepth", arg)
		else
			bare[#bare + 1] = arg
		end
		i += 1
	end

	-- `-type f` and `-type d` are the reflex; LuaSourceContainer is the real
	-- superclass of Script/LocalScript/ModuleScript, so "f" has an exact answer.
	--
	-- "d" does not. Folder is the obvious analogue and the wrong one: a place is
	-- organised with Models, Tools, services and Configurations just as often,
	-- and every Instance can hold children, so `-type d` matching Folder alone
	-- reported nothing at all in most real places. In a filesystem metaphor the
	-- honest split is the one that already exists — a script is a file, and
	-- everything else is a thing you can descend into.
	if class == "f" then
		class = "LuaSourceContainer"
	elseif class == "d" then
		class = "!LuaSourceContainer"
	end

	-- A bare `find` would otherwise fall through to pattern "*" from the cwd,
	-- which at / means walking every descendant of the DataModel for nothing.
	if not named and not class and #bare == 0 then
		return "find: requires a pattern or a path"
	end

	-- `find / -type f` has no name at all, and `find Handler` has no path, so
	-- the bare operands are classified by shape rather than position: a leading
	-- / or a bare . is unambiguously a root, anything else is the pattern.
	local pattern = named
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

	local s, err = self:find(pattern or "*", root, class, depth)
	return s or fail("find", err)
end

HANDLERS.which = function(self, argv)
	local _, operands = partition(argv)
	local name = operands[1]
	if not name or name == "" then
		return "which: requires a name"
	end
	-- `which` answers "what runs when I type this", so the command table is the
	-- only correct place to look first. It used to go straight to find(), which
	-- searched the DataModel for an INSTANCE named "grep" and reported whichever
	-- unrelated thing it happened to hit — an answer that looked authoritative
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
	-- the word could mean here, so keep it — just no longer as the first answer.
	local s, err = self:find(name, operands[2])
	if not s then
		return fail("which", err)
	end
	return (s:split("\n"))[1]
end

-- A pattern using these almost certainly meant regex. `.` is excluded on
-- purpose: `game.Workspace` is ordinary code, not an attempt at a wildcard.
local REGEXISH = "[\\%[%]%^%$%*%+%|%?]"

-- Regex escapes with an exact Lua-pattern equivalent.
local ESCAPES: { [string]: string } = {
	s = "%s", S = "%S", d = "%d", D = "%D", w = "%w", W = "%W",
	a = "%a", A = "%A", l = "%l", L = "%L", u = "%u", U = "%U",
	p = "%p", P = "%P", x = "%x", X = "%X",
	t = "\t", n = "\n", r = "\r",
}

-- `-E` means "extended regex" everywhere else in the world; the engine here is
-- Lua patterns. The flag name is not going to stop being typed, so translate the
-- escapes that map exactly and REFUSE the constructs that do not.
--
-- Refusing matters more than translating. `grep -nE "^\t###"` used to search for
-- a literal backslash-t and report "no matches" — a still-broken pattern reading
-- as a verified-absent result, which is the one output an agent has no way to
-- doubt. An error is a retry; a wrong "no matches" is a wrong conclusion.
local function luaPattern(regex: string): (string?, string?)
	if regex:find("|", 1, true) then
		return nil, "Lua patterns have no | alternation — grep twice, or match the common part"
	end
	if regex:find("%(%?") then
		return nil, "Lua patterns have no (?...) groups"
	end
	if regex:find("[%*%+%?]%?") then
		return nil, "Lua patterns have no lazy quantifiers — `-` is the lazy repeat, as in `.-`"
	end
	if regex:find("{%d") then
		return nil, "Lua patterns have no {n,m} repetition — write the repeats out"
	end
	local unknown: string? = nil
	local out = regex:gsub("\\(.)", function(c)
		local mapped = ESCAPES[c]
		if mapped then
			return mapped
		end
		if c:match("%w") then
			unknown = unknown or c
			return c
		end
		-- \. \( \[ — escaping a literal, which Lua spells with %.
		return "%" .. c
	end)
	if unknown then
		return nil, string.format("\\%s has no Lua-pattern equivalent (%%s %%d %%a %%w, not \\s \\d \\a \\w)", unknown)
	end
	return out, nil
end

-- -A/-B/-C carry a count, which partition cannot represent — it returns a flag
-- SET and a list of operands, so `grep -A 3 pat f` left `3` sitting where the
-- path belongs and the search reported `no child named "3"`. The error named the
-- argument for the absence of the flag, which is the single most expensive
-- failure mode this shell had. Lifted out of argv first, the way find does.
local function takeContext(argv: { string }): ({ string }, number, number, string?)
	local kept: { string } = { argv[1] }
	local before, after = 0, 0
	local i = 2
	while i <= #argv do
		local arg = argv[i]
		local letter, glued = arg:match("^%-([ABC])(%d*)$")
		if letter then
			local count = tonumber(glued)
			if not count then
				count = tonumber(argv[i + 1] or "")
				if not count then
					return kept, 0, 0, string.format(
						"-%s needs a number of lines, as `-%s 3` or `-%s3`", letter, letter, letter)
				end
				i += 1
			end
			if letter ~= "B" then after = count end
			if letter ~= "A" then before = count end
		else
			kept[#kept + 1] = arg
		end
		i += 1
	end
	return kept, before, after, nil
end

-- Render hits: the path once per file, then `N: text` for a match and `N- text`
-- for a context line, with `--` between non-adjacent runs — grep's own
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
		-- began — grep prints the separator between CONTEXT groups, not hits.
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
	local args, before, after, contextErr = takeContext(argv)
	if contextErr then
		return fail("grep", contextErr)
	end
	local flags, operands = partition(args)
	if flags["-A"] or flags["-B"] or flags["-C"] then
		-- Survived takeContext, so it arrived bundled: `-nA3`, where the count
		-- cannot be told from the flag letters. Naming it beats guessing.
		return fail("grep", "give -A/-B/-C their own argument, as `grep -n -A 3 pat f`")
	end

	local pattern = operands[1]
	if not pattern or pattern == "" then
		return fail("grep", "requires a pattern")
	end
	local usePattern = flags["-E"] or flags["-P"] or flags["-e"]
	if usePattern then
		local translated, patternErr = luaPattern(pattern)
		if not translated then
			return fail("grep", patternErr)
		end
		pattern = translated
	end

	local opts = {
		usePattern = usePattern,
		-- Case-SENSITIVE by default, which is what grep means everywhere else.
		-- Both sides used to be lowercased unconditionally, so a search for
		-- `Humanoid` also returned `humanoid` and there was no way to ask for the
		-- strict form — a wrong answer that looks exactly like a right one.
		ignoreCase = flags["-i"] or false,
		invert = flags["-v"] or false,
		before = before,
		after = after,
	}

	-- Piped in: filter the stream. A path operand still wins, the way it does in
	-- a shell — `grep x file` ignores stdin.
	if stdin and not operands[2] then
		if usePattern and not pcall(string.find, "", pattern) then
			return fail("grep", "not a valid Lua pattern: " .. tostring(operands[1]))
		end
		local hits = Fs.grepLines(splitLines(stdin), pattern, opts)
		if flags["-c"] then
			local matches = 0
			for _, hit in ipairs(hits) do
				if hit.match then matches += 1 end
			end
			return tostring(matches)
		end
		-- Line numbers of a stream are the stream's, not a file's, so they are
		-- only worth printing when asked for.
		return #hits > 0
			and formatHits(hits, false, flags["-n"] == true, before + after > 0)
			or "no matches"
	end

	local hits, err = self:grep(pattern, operands[2], opts)
	if not hits then
		return fail("grep", err)
	end
	if #hits == 0 then
		if flags["-c"] then
			return "0"          -- a count, since that is what was asked for
		end
		-- "no matches" is indistinguishable from "this grep never understood
		-- your pattern", and an agent that cannot tell them apart retries the
		-- regex, then reaches for a pipe, then gives up on the shell entirely.
		if not usePattern and pattern:find(REGEXISH) then
			return "no matches — grep matches literal text, so that pattern was searched " ..
				"character for character. Use a plain substring, or `grep -E` for a regex " ..
				"(translated to Lua patterns; no | alternation)."
		end
		-- grep only became case-sensitive recently, and the regression that change
		-- risks is exactly this: a search that used to find something now returns
		-- a clean "no matches". Retrying insensitively costs one extra walk, and
		-- only ever on a search that already failed.
		if not flags["-i"] then
			local insensitive = self:grep(pattern, operands[2],
				{ usePattern = usePattern, invert = opts.invert, ignoreCase = true })
			if insensitive and #insensitive > 0 then
				return string.format("no matches — %d with `grep -i` (grep is case-sensitive)",
					#insensitive)
			end
		end
		return "no matches"
	end

	local matches = 0
	for _, hit in ipairs(hits) do
		if hit.match then matches += 1 end
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

	local body = formatHits(hits, true, true, before + after > 0)
	local skipped = (hits :: any).skipped
	if skipped then
		body ..= string.format("\n… %d more matches (narrow the path or the pattern)", skipped)
	end
	return body
end

HANDLERS.sort = function(self, argv, stdin)
	local flags, operands = partition(argv)
	local input, inputErr = textInput(self, operands, stdin)
	if not input then return fail("sort", inputErr) end
	local lines = splitLines(input)
	table.sort(lines, function(a, b)
		if flags["-r"] then
			return a > b
		end
		return a < b
	end)
	if flags["-u"] then
		local seen: { [string]: boolean } = {}
		local unique: { string } = {}
		for _, line in ipairs(lines) do
			if not seen[line] then
				seen[line] = true
				unique[#unique + 1] = line
			end
		end
		lines = unique
	end
	return table.concat(lines, "\n")
end

-- Adjacent-only, as in bash: `sort | uniq` is the idiom, and silently doing a
-- global dedupe would make `uniq -c` counts wrong for anyone who relies on it.
HANDLERS.uniq = function(self, argv, stdin)
	local flags, operands = partition(argv)
	local input, inputErr = textInput(self, operands, stdin)
	if not input then return fail("uniq", inputErr) end
	local out: { string } = {}
	local counts: { number } = {}
	for _, line in ipairs(splitLines(input)) do
		if out[#out] == line then
			counts[#counts] += 1
		else
			out[#out + 1] = line
			counts[#counts + 1] = 1
		end
	end
	if flags["-c"] then
		for index, line in ipairs(out) do
			out[index] = string.format("%4d %s", counts[index], line)
		end
	end
	return table.concat(out, "\n")
end

HANDLERS.mkdir = function(self, argv)
	local _, operands = partition(argv)
	-- mkdir names a path, so split the last segment off.
	local dir = operands[1]
	if not dir or dir == "" then
		return "mkdir: requires a name"
	end
	local parentPath, leaf = splitPath(dir)
	local s, err = self:create("Folder", leaf, parentPath)
	return s or fail("mkdir", err)
end

HANDLERS.touch = function(self, argv)
	local _, operands = partition(argv)
	local target = operands[1]
	if not target or target == "" then
		return "touch: requires a name"
	end
	local parentPath, leaf = splitPath(target)
	local class, name = classFor(leaf)
	local s, err = self:create(class, name, parentPath)
	return s or fail("touch", err)
end

HANDLERS.rm = function(self, argv)
	local _, operands = partition(argv)
	local s, err = self:remove(operands[1])
	return s or fail("rm", err)
end

HANDLERS.mv = function(self, argv)
	local _, operands = partition(argv)
	local s, err = self:move(operands[1], operands[2], operands[3])
	return s or fail("mv", err)
end

HANDLERS.cp = function(self, argv)
	local _, operands = partition(argv)
	local s, err = self:copy(operands[1], operands[2], operands[3])
	return s or fail("cp", err)
end

HANDLERS.ln = function(self, argv)
	-- An ObjectValue is the DataModel's reference-to-another-instance, which is
	-- as close as this tree gets to a symlink. It does not behave like one for
	-- cd or cat — nothing resolves through it — so the result says so.
	local _, operands = partition(argv)
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

-- `sed -n '10,40p'` — an address range, the one non-substitution form worth
-- having. Reading an arbitrary window of a script was otherwise `head -N | tail
-- -M` and a subtraction the caller had to do correctly every time; getting it
-- wrong returns a plausible block from the wrong place, which is the expensive
-- kind of mistake. `$` is the last line, as it is everywhere else.
--
-- Returns nil,nil,nil when `expr` is not an address at all, so the caller can
-- fall through to substitution rather than having to pre-classify it.
local function parseRange(expr: string, total: number): (number?, number?, string?)
	local body = expr:match("^(.-)p$")
	if not body then
		return nil, nil, nil
	end
	local first, last = body:match("^([%d%$]+),([%d%$]+)$")
	if not first then
		first = body:match("^([%d%$]+)$")
		last = first
	end
	if not first then
		return nil, nil, nil
	end
	local function lineOf(token: string): number?
		return token == "$" and total or tonumber(token)
	end
	local from, to = lineOf(first), lineOf(last :: string)
	if not from or not to then
		return nil, nil, "malformed address, expected N,Mp / Np / N,$p / $p"
	end
	if from > to then
		return nil, nil, string.format("empty range: line %d comes after line %d", from, to)
	end
	return math.max(1, from), math.min(total, to), nil
end

HANDLERS.sed = function(self, argv, stdin)
	local flags, operands = partition(argv)
	local expr = operands[1]
	if not expr then
		return fail("sed", "requires an expression, e.g. s/old/new/ or -n '10,40p'")
	end

	-- Address forms are everything that is not `s<delim>`, so classify on the
	-- delimiter rather than the leading letter — otherwise `$p` and `10,40p`
	-- would both have to be special-cased ahead of the substitution parser.
	local isSubstitution = expr:sub(1, 1) == "s" and expr:sub(2, 2):match("%p") ~= nil
	if not isSubstitution then
		local input, inputErr = textInput(self, { operands[2] }, stdin)
		if not input then
			return fail("sed", inputErr)
		end
		if flags["-i"] then
			-- Real sed would happily truncate the file to the printed range. That
			-- is a destructive reading of a command whose whole purpose here is to
			-- read, so it is refused rather than performed.
			return fail("sed", "-i with an address range would overwrite the file with just that range; drop -i")
		end
		local lines = splitLines(input)
		local from, to, rangeErr = parseRange(expr, #lines)
		if rangeErr then
			return fail("sed", rangeErr)
		end
		if not from then
			return fail("sed", string.format(
				"unsupported expression %q — sed here does substitution (s/old/new/[g]) " ..
					"and address ranges (-n '10,40p', -n '5p', -n '10,$p')", expr))
		end
		if (from :: number) > #lines then
			return string.format("(no lines: file has %d)", #lines)
		end
		return table.concat(lines, "\n", from :: number, to :: number)
	end

	local delim = expr:sub(2, 2)
	if not delim or delim:match("%s") then
		return fail("sed", "invalid delimiter")
	end
	local rest = expr:sub(3)
	local parts = {}
	local current = {}
	local escaped = false
	for i = 1, #rest do
		local c = rest:sub(i, i)
		if escaped then
			current[#current + 1] = c
			escaped = false
		elseif c == "\\" then
			escaped = true
		elseif c == delim then
			parts[#parts + 1] = table.concat(current)
			current = {}
		else
			current[#current + 1] = c
		end
	end
	parts[#parts + 1] = table.concat(current)

	if #parts < 3 then
		return fail("sed", "malformed expression, expected s/old/new/[g]")
	end

	local pattern = parts[1]
	local replacement = parts[2]
	local mod = parts[3] or ""

	local isGlobal = mod:find("g") ~= nil

	-- operands[1] is the expression, so the file (if any) is operands[2].
	local input, inputErr = textInput(self, { operands[2] }, stdin)
	if not input then
		return fail("sed", inputErr)
	end
	if flags["-i"] and not operands[2] then
		return fail("sed", "-i edits a file in place, so it needs a file operand")
	end

	-- A bad pattern — or a replacement naming a capture that does not exist —
	-- used to leave the line unmodified and carry on, so the whole file came back
	-- verbatim and reported success. With `-i` that is invisible: the write lands,
	-- nothing changed, and reading it back confirms it. Fail on the first throw
	-- instead. Checked in the loop rather than up front because gsub only rejects
	-- a bad replacement when a match actually reaches it.
	local out = {}
	for _, line in ipairs(splitLines(input)) do
		local ok, res = pcall(string.gsub, line, pattern, replacement, not isGlobal and 1 or nil)
		if not ok then
			return fail("sed", string.format("%s — sed takes Lua patterns (%%s %%d %%a, " ..
				"not \\s \\d \\w), and %% in a replacement means a capture",
				(tostring(res):gsub("^.-:%d+: ", ""))))
		end
		out[#out + 1] = res
	end
	local result = table.concat(out, "\n")

	-- `sed -i` writes back, which is the whole point of the flag. It goes
	-- through :write, so the substitution lands in one undo record like every
	-- other mutation rather than being the one edit Ctrl+Z cannot reach.
	if flags["-i"] then
		local s, writeErr = self:write(operands[2], result .. "\n")
		return s or fail("sed", writeErr)
	end
	return result
end

HANDLERS.diff = function(self, argv)
	local _, operands = partition(argv)
	if not operands[1] or not operands[2] then
		return fail("diff", "requires two paths to compare")
	end
	local a, errA = self:resolve(operands[1])
	if not a then return fail("diff", errA) end
	local b, errB = self:resolve(operands[2])
	if not b then return fail("diff", errB) end

	local srcA = getSource(a) or ""
	local srcB = getSource(b) or ""
	if srcA == srcB then return "" end

	local linesA = splitLines(srcA)
	local linesB = splitLines(srcB)

	local maxLines = math.max(#linesA, #linesB)
	local out = {}
	for i = 1, maxLines do
		local lA = linesA[i]
		local lB = linesB[i]
		if lA ~= lB then
			if lA then table.insert(out, string.format("< %s", lA)) end
			if lB then table.insert(out, string.format("> %s", lB)) end
		end
	end
	return table.concat(out, "\n")
end

local function expandTrSet(s: string): string
	local expanded = {}
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
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

HANDLERS.tr = function(self, argv, stdin)
	local _, operands = partition(argv)
	local set1 = expandTrSet(operands[1] or "")
	local set2 = expandTrSet(operands[2] or "")
	if set1 == "" or set2 == "" then
		return fail("tr", "requires two character sets, e.g. tr a-z A-Z")
	end
	-- Both sets are operands, so a file (if any) is the third.
	local input, inputErr = textInput(self, { operands[3] }, stdin)
	if not input then
		return fail("tr", inputErr)
	end
	local out = {}
	for _, line in ipairs(splitLines(input)) do
		local mapped = line:gsub(".", function(c)
			local pos = set1:find(c, 1, true)
			if pos and pos <= #set2 then
				return set2:sub(pos, pos)
			end
			return c
		end)
		out[#out + 1] = mapped
	end
	return table.concat(out, "\n")
end

HANDLERS.basename = function(_, argv)
	local _, operands = partition(argv)
	if not operands[1] then return "" end
	local parts = operands[1]:split("/")
	return parts[#parts] or ""
end

HANDLERS.dirname = function(_, argv)
	local _, operands = partition(argv)
	if not operands[1] then return "" end
	local parent, _ = operands[1]:match("^(.*)/([^/]+)$")
	return parent or "/"
end

-- Aliases: same behaviour, different muscle memory.
HANDLERS.file = HANDLERS.stat
HANDLERS.rmdir = HANDLERS.rm
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
-- is exempt — `grep "<" f` is a pattern, not a redirection — which is what the
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

-- The flag letters each command accepts, checked once here rather than in every
-- handler. A command absent from this table is unchecked: `find` parses its own
-- GNU-style long flags and refuses unknown ones itself, and `echo` has no flags
-- because everything after it is data.
--
-- An empty string means "takes none", which is a real answer and not the same as
-- being absent — `cat -A` should say so rather than quietly ignore the flag.
local FLAGS: { [string]: string } = {
	basename = "", cat = "", cd = "", diff = "", dirname = "", du = "",
	file = "", grep = "ABCEPceilnv", head = "cn", ln = "s", ls = "l",
	mkdir = "", mv = "", rm = "rf", cp = "r", sed = "in", sort = "ru",
	stat = "", tail = "cn", touch = "", tr = "", tree = "L", uniq = "c",
	wc = "clw", which = "",
}
FLAGS.egrep = FLAGS.grep
FLAGS.fgrep = FLAGS.grep
FLAGS.rmdir = FLAGS.rm

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
	-- READ_ONLY is an allowlist of COMMANDS, and `sed` earned its place there by
	-- only ever filtering a stream. `-i` writes the result back, so that one flag
	-- turns an allowlisted command into a mutating one and has to be named
	-- explicitly — otherwise adding in-place editing quietly punches a hole in
	-- /sh, which exists so that every mutation arrives through Claude with an
	-- undo recording attached.
	if readOnly and cmd == "sed" then
		for _, arg in ipairs(args) do
			if arg == "-i" then
				return fail("bash", "sed -i writes to the script — /sh is read-only"), false
			end
		end
	end
	if stdin and not STDIN_COMMANDS[cmd] then
		return fail("bash", cmd .. " does not read input — pipe into cat, grep, head, tail, wc, sort, uniq, sed or tr"), false
	end
	-- Before the handler, so an unknown flag fails on its own terms instead of
	-- surviving as an ignored flag and a stray positional argument.
	local _, _, flagErr = partition(args, FLAGS[cmd])
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
-- should stay Claude's — every write it makes carries an undo recording.
function Shell.run(self: any, line: string?, readOnly: boolean?): string
	local commandLine, stdin, heredocErr = extractHeredoc(line or "")
	if heredocErr then
		return "bash: " .. heredocErr
	end

	-- There is no stderr here — errors come back as ordinary output — so the
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

-- =============================================================================
-- Self-test
-- =============================================================================
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

	-- Flag forms all have to land on the same (path, count).
	for _, line in ipairs({ "head -n 20 /a", "head -20 /a", "head /a 20", "head /a -n 20" }) do
		local argv = tokenize(line) :: { string }
		local _, operands = partition(argv)
		local path, count = takeCount(operands)
		if path ~= "/a" or count ~= 20 then
			return false, string.format("%q parsed as (%s, %s)", line, tostring(path), tostring(count))
		end
	end

	-- Script suffixes. `ls` renders every script class as `.luau`, but a model
	-- writes whichever form it knows, and all of them have to land on the same
	-- instance — the class is a property in the DataModel, never part of a name.
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
	-- misses it and every path a model writes lowercase used to fail — including
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
	-- is a header emitted per hit, which is silent — the output still reads fine,
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
		{ line = "grep -C 1 gamma Sample.luau",
		  want = "/Sample\n  2- beta\n  3: gamma\n  4- delta", why = "grep -C both sides" },
		{ line = "grep Humanoid Cased.luau", want = "/Cased\n  1: Humanoid",
		  why = "grep is case-sensitive" },
		{ line = "grep -ci Humanoid Cased.luau", want = "2", why = "grep -i" },
		{ line = "grep -cE '\\a+' Sample.luau", want = "5", why = "-E translates \\a to %a" },
		-- A quoted metacharacter is a one-character pattern, not a redirection.
		{ line = 'echo "<"', want = "<", why = "quoted metacharacter is data" },
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
			{ line = "grep -Z needle Sample.luau", want = "unsupported flag %-Z" },
			{ line = "head -Q Sample.luau", want = "unsupported flag %-Q" },
			{ line = 'grep -E "a|b" Sample.luau', want = "alternation" },
			{ line = 'grep -E "\\q" Sample.luau', want = "no Lua%-pattern equivalent" },
			{ line = "sed -n '9,2p' Sample.luau", want = "empty range" },
			-- A malformed pattern used to leave every line unmodified and report
			-- success — invisible under -i, where the write lands and changes
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
	if not Shell.run(probe, "chmod 777 /Workspace"):match("permission bits") then
		return false, "UNSUPPORTED lookup is not firing"
	end

	-- Stderr redirections must be swallowed rather than rejected. `&` is a
	-- metacharacter, so before these were stripped a trailing `2>&1` — about the
	-- most reflexive thing there is to append to a command — failed the line.
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

	-- sed -i mutates, so /sh must refuse it however the allowlist reads.
	if not Shell.run(probe, "sed -i s/a/b/ x.luau", true):match("read%-only") then
		return false, "sed -i is not blocked in read-only mode"
	end

	-- -type has to reject a name that is not a class. IsA() cannot do this — it
	-- returns false rather than throwing — so a regression here shows up as a
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

	return true, nil
end

return Shell
