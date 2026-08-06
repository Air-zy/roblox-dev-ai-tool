--!optimize 2
-- Terminal.luau — the commands, as operations on the DataModel.
--
-- Every command here does one thing to the tree and returns text: list a
-- container, read a script, diff its properties against a default instance,
-- clone it, move it, execute Luau. None of them know about quoting, pipes or
-- argument parsing — that is Shell's half, and it calls into these.
--
-- What lives where:
--   Fs        path resolution, .Source access, undo recording, glob matching
--   Props     property names + default baselines, from the API dump
--   here      the commands themselves, as methods on a Terminal
--   Shell     the command line: tokenizer, HANDLERS, pipelines, redirection
--   Tools     the tool registry; tools/ has one file per tool
--
-- Commands are reached through the `bash` tool. Everything carrying a Luau
-- payload — edit, multiedit, write, run — is a separate tool instead, because
-- routing source through shell quoting would eventually corrupt someone's script
-- and JSON parameters already solve escaping. The split is on payload, not risk.
--
-- Deliberately NOT here: separate ls/grep/glob tools duplicating the shell ones.
-- Two routes to one function means the model has to choose, every time, for no
-- gain — there are no pipes here for a structured variant to avoid.
--
-- Path semantics live in Fs; see that file.

local game = game
local ipairs = ipairs
local pairs = pairs
local string = string
local table = table
local tostring = tostring
local type = type
local typeof = typeof
local pcall = pcall
local Instance = Instance

local Fs    = require(script.Parent:WaitForChild("Fs"))
local Props = require(script.Parent:WaitForChild("Props"))
local isScript        = Fs.isScript
local getSource       = Fs.getSource
local splitLines      = Fs.splitLines
local instancePath    = Fs.instancePath
local withUndo        = Fs.withUndo
local guardProtected  = Fs.guardProtected
local formatValue     = Fs.formatValue
local countOccurrences = Fs.countOccurrences
local splitPath       = Fs.splitPath
local nameMatcher     = Fs.nameMatcher
local displayName     = Fs.displayName

local Terminal = {}
Terminal.__index = Terminal

function Terminal.new(startInstance: Instance?)
	local self = setmetatable({}, Terminal)
	self.cwd = startInstance or game
	return self
end

-- The cwd is the only per-terminal state; path resolution itself is stateless.
function Terminal:resolve(path: string?): (Instance?, string?)
	return Fs.resolve(self.cwd, path)
end

function Terminal:current(): Instance
	return self.cwd
end

function Terminal:pwd(): string
	return instancePath(self.cwd)
end

function Terminal:cd(path: string?): (boolean, string?)
	local target, err = self:resolve(path)
	if not target then
		return false, err or "resolve failed"
	end
	self.cwd = target
	return true, nil
end

-- Property names and default-value baselines come from Props, which owns the
-- API dump and the one piece of network I/O in the harness.
local propertyNames = Props.names
local defaultFor    = Props.default
local classExists   = Props.classExists

-- Same discipline as run's output cap. An unbounded grep across a large place
-- returns thousands of lines and evicts the context that made the search worth
-- running — which is the real reason to want `| head`, and cheaper to fix here
-- than by growing a shell.
local MAX_RESULTS = 100

-- The single largest token sink in the whole harness: one `cat` of a 3000-line
-- module costs more context than every other command in a session combined.
-- Claude Code caps reads for the same reason. Paging is reachable now that
-- pipes exist — `head -n 1200 f | tail -n 200` gets an arbitrary window.
local MAX_CAT_LINES = 1000

local function capped(results: { string }, noun: string): string
	if #results <= MAX_RESULTS then
		return table.concat(results, "\n")
	end
	return string.format("%s\n… %d more %s (narrow the path or the pattern)",
		table.concat(results, "\n", 1, MAX_RESULTS), #results - MAX_RESULTS, noun)
end

-- =============================================================================
-- Commands
-- =============================================================================

-- list
function Terminal:ls(path: string?, long: boolean?, filter: ((string) -> boolean)?): ({string}?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local names = {}
	for _, child in ipairs(target:GetChildren()) do
		-- Appends .luau to scripts so Claude knows they're editable files.
		local name = displayName(child)
		-- Filter on the displayed name, so `ls *.luau` means what it looks like.
		if not filter or filter(name) then
			if long then
				-- No column padding and no "0 children". Alignment is for eyes; the
				-- reader here is a model, and on a 200-part listing the padding
				-- plus a zero count on every leaf is most of the bytes.
				--
				-- Line count for scripts, because "how big is this file" is the
				-- question `ls -l` is asked and children were the only answer it
				-- had — which sent people to `stat` one path at a time, or to the
				-- run tool to count `#Source` themselves.
				local kids = #child:GetChildren()
				local source = getSource(child)
				name = string.format("%s [%s]%s%s", name, child.ClassName,
					source and string.format("  %d lines", #splitLines(source)) or "",
					kids > 0 and string.format("  %d children", kids) or "")
			end
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names, nil
end

-- cat: if script, return source. Otherwise, dump the properties that differ
-- from a default instance of the same class.
function Terminal:cat(path: string?): (string?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end

	-- If it's a script, return the source code (like `cat file.lua`)
	local source = getSource(target)
	if source then
		local lines = splitLines(source)
		if #lines <= MAX_CAT_LINES then
			return source, nil
		end
		-- The range form rather than `head | tail`, which needed a subtraction on
		-- every call — `head -640 | tail -80` for lines 560-640 — and getting it
		-- wrong returns a plausible block from the wrong part of the file.
		return string.format("%s\n… TRUNCATED: %d of %d lines shown. Page the rest with " ..
			"`sed -n '%d,%dp' %s`, or grep for what you need.",
			table.concat(lines, "\n", 1, MAX_CAT_LINES), MAX_CAT_LINES, #lines,
			MAX_CAT_LINES + 1, math.min(#lines, MAX_CAT_LINES * 2), instancePath(target)), nil
	end

	local className = target.ClassName
	local lines = {}
	table.insert(lines, string.format("Name: %s", target.Name))
	table.insert(lines, string.format("ClassName: %s", className))
	table.insert(lines, string.format("Path: %s", instancePath(target)))
	table.insert(lines, string.format("Children: %d", #target:GetChildren()))

	local names, listErr = propertyNames(className)
	if not names then
		table.insert(lines, "(properties unavailable: " .. tostring(listErr) .. ")")
		return table.concat(lines, "\n"), nil
	end

	local default = defaultFor(className)
	local shown = 0
	for _, propName in ipairs(names) do
		-- Name is already in the header; Parent is implied by Path and would
		-- always differ from a default instance's nil.
		if propName ~= "Name" and propName ~= "Parent" then
			local ok, value = pcall(function()
				return (target :: any)[propName]
			end)
			if ok then
				local isDefault = false
				if default then
					local defaultOk, defaultValue = pcall(function()
						return (default :: any)[propName]
					end)
					isDefault = defaultOk and defaultValue == value
				end
				if not isDefault then
					table.insert(lines, string.format("%s: %s", propName, formatValue(value)))
					shown += 1
				end
			end
		end
	end

	if default then
		if shown == 0 then
			table.insert(lines, "(all properties at default)")
		end
	else
		-- Non-creatable class: no baseline, so the list above is everything.
		table.insert(lines, string.format("(%d properties; no default baseline for %s)", shown, className))
	end

	return table.concat(lines, "\n"), nil
end

-- stat: metadata only (no source, no property values)
function Terminal:stat(path: string?): (string?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local lines = {}
	table.insert(lines, string.format("Name: %s", target.Name))
	table.insert(lines, string.format("ClassName: %s", target.ClassName))
	table.insert(lines, string.format("Path: %s", instancePath(target)))
	table.insert(lines, string.format("Children: %d", #target:GetChildren()))
	local source = getSource(target)
	if source then
		table.insert(lines, string.format("Lines: %d", #splitLines(source)))
		table.insert(lines, "Type: script")
	end
	-- No `Parent:` line — `Path:` above already ends with it.
	if not source then
		-- stat is metadata, the way it is everywhere else, and `cat` is what
		-- prints the property values. That split is obvious once you know it and
		-- invisible before — someone reading this output concluded the harness
		-- could not see Size or CFrame at all and went to the `run` tool for
		-- something `cat` does directly. One line is cheaper than that detour.
		table.insert(lines, "(property values: cat " .. instancePath(target) .. ")")
	end
	return table.concat(lines, "\n"), nil
end

-- head: first n lines of a script
function Terminal:head(path: string?, n: number?): (string?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local source = getSource(target)
	if not source then
		return nil, "not a script: " .. instancePath(target)
	end
	local all = splitLines(source)
	local count = math.min(n or 10, #all)
	return table.concat(all, "\n", 1, count), nil
end

-- tail: last n lines of a script
function Terminal:tail(path: string?, n: number?): (string?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local source = getSource(target)
	if not source then
		return nil, "not a script: " .. instancePath(target)
	end
	local all = splitLines(source)
	local startIdx = math.max(1, #all - (n or 10) + 1)
	return table.concat(all, "\n", startIdx, #all), nil
end

-- find: recursively match instance names, optionally filtered by class and depth.
function Terminal:find(name: string?, path: string?, className: string?, maxDepth: number?): (string?, string?)
	if not name or name == "" then
		return nil, "find requires a name pattern"
	end
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end

	-- A leading "!" negates the class filter. Only `-type d` produces one, but
	-- keeping it general costs one branch and means the negation lives with the
	-- matching rather than as a special case in the argument parser.
	local negate = false
	if className and className:sub(1, 1) == "!" then
		negate = true
		className = className:sub(2)
	end

	-- IsA() does NOT throw on a class name that doesn't exist — per the Roblox
	-- docs it "will always return false". The pcall that used to live here
	-- therefore never fired once, and a typo'd or invented -type walked the
	-- entire subtree matching nothing and reported a bare "no matches", which
	-- reads exactly like "your pattern was wrong" rather than "that filter was
	-- never a class". Validate against the dump instead, once, before the walk.
	if className and className ~= "" and not classExists(className) then
		return nil, string.format(
			"not a class name: %s — try -type f (scripts), -type d (folders), " ..
				"or a real ClassName like Part, Tool, RemoteEvent", className)
	end

	-- A recursive walk rather than GetDescendants(), so -maxdepth can stop early
	-- instead of building the whole list and filtering it afterwards.
	local matches = nameMatcher(name)
	local limit = maxDepth or math.huge
	local results = {}
	local function walk(inst: Instance, depth: number)
		if depth > limit then
			return
		end
		for _, child in ipairs(inst:GetChildren()) do
			-- Matched against the DISPLAYED name as well as the real one. `ls`
			-- prints scripts as `Main.luau`, so a model that read a listing will
			-- reasonably search for `*.luau` — and no instance name has ever
			-- contained that suffix, so matching only child.Name meant the most
			-- natural search in the whole harness silently returned nothing.
			local classOk = not className or className == "" or (child:IsA(className) ~= negate)
			if (matches(child.Name) or matches(displayName(child))) and classOk then
				table.insert(results, instancePath(child) .. "  [" .. child.ClassName .. "]")
			end
			walk(child, depth + 1)
		end
	end
	walk(target, 1)

	if #results == 0 then
		return "no matches", nil
	end
	return capped(results, "matches"), nil
end

-- grep: search script sources. Literal by default — that is the right default
-- for code search, where `game.Workspace` and `foo(bar)` are full of characters
-- a regex would eat. `usePattern` switches to Lua patterns, which is the dialect
-- actually available here; there is no POSIX regex engine to fall back to.
--
-- Returns STRUCTURED results, not text. It used to return `path:N: text` lines
-- joined into one string, which the shell then re-parsed three separate ways —
-- splitting on "\n" to count for -c, regexing the path back out for -l, and
-- splitting on ":" again to group by file. Every one of those was undoing work
-- this function had just done, and none of them could carry a context line.
-- Formatting belongs to the caller; finding belongs here.
export type GrepMatch = { path: string, line: number, text: string, match: boolean }

function Terminal:grep(pattern: string?, path: string?, opts: Fs.GrepOpts?): ({ GrepMatch }?, string?)
	if not pattern or pattern == "" then
		return nil, "grep requires a pattern"
	end
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local o: Fs.GrepOpts = opts or {}

	if o.usePattern then
		-- Validate once. A malformed pattern throws from find(), and checking
		-- per line would mean a pcall for every line of every script in scope.
		local ok = pcall(string.find, "", o.ignoreCase and pattern:lower() or pattern)
		if not ok then
			return nil, "not a valid Lua pattern: " .. pattern
		end
	end

	local results: { GrepMatch } = {}
	local budget = MAX_RESULTS
	local skipped = 0
	-- Include the target: `grep foo Main.luau` means search Main, and walking
	-- only descendants made that silently return "no matches". GetDescendants
	-- hands back a fresh table, so prepending to it is safe.
	local scope = target:GetDescendants()
	table.insert(scope, 1, target)
	for _, inst in ipairs(scope) do
		local source = getSource(inst)
		if source then
			-- The cap counts MATCHES, not emitted lines, and is applied before the
			-- context window opens — otherwise `-C 5` would quietly return six
			-- times the budget and evict the context that made the search worth
			-- running, which is the one thing MAX_RESULTS exists to prevent.
			local hits, taken, refused = Fs.grepLines(splitLines(source), pattern, {
				usePattern = o.usePattern,
				ignoreCase = o.ignoreCase,
				before = o.before,
				after = o.after,
				limit = budget,
			})
			budget -= taken
			skipped += refused
			if #hits > 0 then
				local instPath = instancePath(inst)
				for _, hit in ipairs(hits) do
					results[#results + 1] = {
						path = instPath, line = hit.line, text = hit.text, match = hit.match,
					}
				end
			end
		end
	end
	-- The cap trailer rides on the list rather than coming back as a third return
	-- value, which is the one a caller drops.
	local tagged: any = results
	if skipped > 0 then
		tagged.skipped = skipped
	end
	return results, nil
end

function Terminal:tree(path: string?, depth: number?): (string?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local maxDepth = depth or 2

	local lines = {}
	local function walk(inst: Instance, prefix: string, d: number)
		if d > maxDepth then return end
		for _, child in ipairs(inst:GetChildren()) do
			local last = child == inst:GetChildren()[#inst:GetChildren()]
			local branch = last and "└── " or "├── "
			local suffix = isScript(child) and ".luau" or ""
			table.insert(lines, prefix .. branch .. child.Name .. suffix .. "  [" .. child.ClassName .. "]")
			local nextPrefix = prefix .. (last and "    " or "│   ")
			walk(child, nextPrefix, d + 1)
		end
	end

	table.insert(lines, instancePath(target))
	walk(target, "", 1)
	return table.concat(lines, "\n"), nil
end

-- =============================================================================
-- Write commands
-- =============================================================================
-- Mutation, undo recording and the protected-instance guard live in Fs; they
-- are aliased at the top of this file.

-- create: make a new instance of className under parentPath. Backs mkdir and
-- touch, which only differ in which className they pass in.
function Terminal:create(className: string, name: string?, parentPath: string?): (string?, string?)
	if not name or name == "" then
		return nil, "create requires a name"
	end
	local parent, err = self:resolve(parentPath)
	if not parent then return nil, err end

	local existing = parent:FindFirstChild(name)
	if existing then
		return string.format("%s already exists", instancePath(existing)), nil
	end

	local created, createErr = withUndo("Claude: create " .. name, function()
		local inst = Instance.new(className)
		inst.Name = name
		inst.Parent = parent
		return inst
	end)
	if createErr then return nil, createErr end
	return string.format("created %s [%s]", instancePath(created :: Instance), className), nil
end

-- write: replace a script's entire source.
function Terminal:write(path: string?, content: string?): (string?, string?)
	if content == nil then
		return nil, "write requires content"
	end
	local target, err = self:resolve(path)
	if not target then return nil, err end
	if not isScript(target) then
		return nil, "not a script: " .. instancePath(target)
	end

	local _, writeErr = withUndo("Claude: write " .. target.Name, function()
		(target :: any).Source = content
	end)
	if writeErr then return nil, writeErr end

	return string.format("wrote %s (%d lines)", instancePath(target), #splitLines(content)), nil
end

-- multiedit: apply substring replacements in order, all or nothing.
--
-- Each old_string must be unique in the source AS OF ITS TURN, so a later edit
-- can legitimately target text an earlier one introduced. Every edit is applied
-- to an in-memory copy and the whole batch is validated before a single
-- assignment lands — that is what lets a failure leave the script byte-identical
-- and the retry safe, instead of half-applied with no way back.
--
-- One withUndo for the batch, so Ctrl+Z reverses the whole thing rather than
-- walking back through it one replacement at a time.
function Terminal:multiedit(path: string?, edits: { any }?): (string?, string?)
	if type(edits) ~= "table" or #edits == 0 then
		return nil, "edits must be a non-empty array of { old_string, new_string }"
	end
	local target, err = self:resolve(path)
	if not target then return nil, err end

	local source = getSource(target)
	if not source then
		return nil, "not a script: " .. instancePath(target)
	end

	local updated = source
	local removed, added = 0, 0
	for index, entry in ipairs(edits) do
		local old = type(entry) == "table" and entry.old_string or nil
		local new = type(entry) == "table" and entry.new_string or nil
		if type(old) ~= "string" or old == "" then
			return nil, string.format("edit %d: old_string must be a non-empty string", index)
		end
		if type(new) ~= "string" then
			return nil, string.format("edit %d: new_string must be a string (use \"\" to delete)", index)
		end

		local matches = countOccurrences(updated, old)
		if matches == 0 then
			return nil, string.format(
				"edit %d: old_string not found in %s — nothing was applied",
				index, instancePath(target))
		end
		if matches > 1 then
			return nil, string.format(
				"edit %d: old_string appears %d times — include surrounding lines to make it unique; nothing was applied",
				index, matches)
		end

		-- Plain find + splice, so neither string is treated as a Lua pattern.
		local start, finish = updated:find(old, 1, true)
		updated = updated:sub(1, (start :: number) - 1) .. new .. updated:sub((finish :: number) + 1)
		removed += #splitLines(old)
		added += #splitLines(new)
	end

	local _, writeErr = withUndo("Claude: edit " .. target.Name, function()
		(target :: any).Source = updated
	end)
	if writeErr then return nil, writeErr end

	return string.format("edited %s (%d changes, -%d/+%d lines)",
		instancePath(target), #edits, removed, added), nil
end

-- edit: the single-replacement case. Same semantics, same undo record.
function Terminal:edit(path: string?, old: string?, new: string?): (string?, string?)
	return self:multiedit(path, { { old_string = old, new_string = new } })
end

-- Resolve a cp/mv destination.
--
-- `cp a b` in a shell means "copy a TO b" — b is a new name unless it is an
-- existing directory. This used to resolve the destination as a parent and
-- nothing else, so the single most common form of both commands failed with
-- "no child named b", and there was no way to copy-and-rename in one step at
-- all. Now: an existing container is still a container, and anything else is
-- read as parent + new name.
local function resolveDestination(self: any, destination: string, name: string?): (Instance?, string?, string?)
	local existing = self:resolve(destination)
	if existing then
		return existing, name, nil
	end
	local parentPath, leaf = splitPath(destination)
	local parent, parentErr = self:resolve(parentPath)
	if not parent then
		return nil, nil, parentErr
	end
	-- `cp Main.luau Backup.luau` means an instance called Backup, not one called
	-- "Backup.luau". The suffix is how `ls` renders a script class, not part of
	-- any name, so carrying it into a new instance would create something that
	-- prints as `Backup.luau.luau` the next time it is listed.
	return parent, name or Fs.stripScriptSuffix(leaf) or leaf, nil
end

-- rm: destroy an instance.
function Terminal:remove(path: string?): (string?, string?)
	if not path or path == "" then
		return nil, "rm requires a path"
	end
	local target, err = self:resolve(path)
	if not target then return nil, err end

	local protected = guardProtected(target)
	if protected then return nil, protected end

	local fullPath = instancePath(target)
	local descendants = #target:GetDescendants()
	local _, removeErr = withUndo("Claude: rm " .. target.Name, function()
		target:Destroy()
	end)
	if removeErr then return nil, removeErr end
	return string.format("removed %s (%d descendants)", fullPath, descendants), nil
end

-- mv: reparent, and optionally rename.
function Terminal:move(path: string?, destination: string?, name: string?): (string?, string?)
	if not path or path == "" or not destination or destination == "" then
		return nil, "mv requires a source path and a destination path"
	end
	local target, err = self:resolve(path)
	if not target then return nil, err end
	local parent, parentErr
	parent, name, parentErr = resolveDestination(self, destination, name)
	if not parent then return nil, parentErr end

	local protected = guardProtected(target)
	if protected then return nil, protected end
	if parent == target or parent:IsDescendantOf(target) then
		return nil, "refusing to move an instance into itself"
	end

	local _, moveErr = withUndo("Claude: mv " .. target.Name, function()
		target.Parent = parent
		if name and name ~= "" then
			target.Name = name
		end
	end)
	if moveErr then return nil, moveErr end
	return string.format("moved to %s", instancePath(target)), nil
end

-- cp: clone an instance (with its descendants) under a new parent.
function Terminal:copy(path: string?, destination: string?, name: string?): (string?, string?)
	if not path or path == "" or not destination or destination == "" then
		return nil, "cp requires a source path and a destination path"
	end
	local target, err = self:resolve(path)
	if not target then return nil, err end
	local parent, parentErr
	parent, name, parentErr = resolveDestination(self, destination, name)
	if not parent then return nil, parentErr end

	if target == game then
		return nil, "refusing to clone the DataModel root"
	end
	if parent == target or parent:IsDescendantOf(target) then
		return nil, "refusing to copy an instance into itself"
	end
	-- Clone() returns nil rather than throwing when Archivable is false, so
	-- without this the failure surfaces as a null-index three lines later.
	if not target.Archivable then
		return nil, string.format("%s is not Archivable and cannot be cloned", instancePath(target))
	end

	local copied, copyErr = withUndo("Claude: cp " .. target.Name, function()
		local clone = target:Clone()
		if name and name ~= "" then
			clone.Name = name
		end
		clone.Parent = parent
		return clone
	end)
	if copyErr then return nil, copyErr end
	return string.format("copied to %s", instancePath(copied :: Instance)), nil
end

-- =============================================================================
-- run — execute Luau in Studio
-- =============================================================================
-- `loadstring` is unavailable to plugins, and shipping one gets a plugin
-- moderated, so execution goes through the supported route: build a
-- ModuleScript, parent it, require it.
--
-- A NEW ModuleScript every call is mandatory, not tidiness. Edit-mode require
-- caches per instance, and that cache does not clear when the source changes —
-- reusing one module would silently return the first run's result forever.
local ServerStorage = game:GetService("ServerStorage")

-- Arbitrary code at plugin permission level can do anything the plugin can:
-- delete the place, fire HTTP requests. Off unless the user opts in.
local runGuard: (() -> boolean)? = nil
function Terminal.setRunGuard(guard: () -> boolean)
	runGuard = guard
end

-- print/warn are shadowed as locals so the chunk's own calls land in __out
-- instead of the Studio output window, where they'd be lost to the agent.
-- Keep this table in sync with nothing else — its LENGTH is the line offset
-- used to translate error line numbers back to the user's code.
local PROLOGUE = {
	'local __out = {}',
	'local function __fmt(...) local n = select("#", ...) local p = table.create(n) for i = 1, n do p[i] = tostring((select(i, ...))) end return table.concat(p, " ") end',
	'local print = function(...) table.insert(__out, __fmt(...)) end',
	'local warn = function(...) table.insert(__out, "[warn] " .. __fmt(...)) end',
	'local __clock = os.clock()',
	'local __ok, __ret = pcall(function()',
}
local EPILOGUE = {
	'end)',
	'return { ok = __ok, ret = __ret, out = __out, elapsed = os.clock() - __clock }',
}
local PROLOGUE_LINES = #PROLOGUE
local MAX_OUTPUT_LINES = 40

-- Shallow, bounded rendering: a returned table is usually the interesting part,
-- but a deep dump of the DataModel would flood the context.
local function describe(value: any, depth: number?): string
	if typeof(value) ~= "table" then
		return formatValue(value)
	end
	if (depth or 0) > 0 then
		return "<table>"
	end
	local parts: { string } = {}
	local count = 0
	for k, v in pairs(value) do
		count += 1
		if count > 10 then
			table.insert(parts, "…")
			break
		end
		table.insert(parts, string.format("%s = %s", tostring(k), describe(v, (depth or 0) + 1)))
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

function Terminal:run(code: string?): (string?, string?)
	if not code or code:match("^%s*$") then
		return nil, "run requires code"
	end
	if not runGuard or not runGuard() then
		return nil, "code execution is disabled — enable it in Settings > Run code"
	end

	local source = table.concat(PROLOGUE, "\n") .. "\n" .. code .. "\n" .. table.concat(EPILOGUE, "\n")

	local module = Instance.new("ModuleScript")
	module.Name = "ClaudeRun_" .. tostring(os.clock()):gsub("%.", "")
	module.Source = source
	module.Parent = ServerStorage

	-- ponytail: no timeout. Luau cannot preempt a running chunk, so
	-- `while true do end` freezes Studio until its own script-exhaustion
	-- timeout fires. The tool description tells Claude to bound its loops;
	-- there is no in-process fix short of running the code in a separate
	-- Actor with a watchdog, which is the upgrade path if this bites.
	local result
	local ranOk, requireErr = pcall(function()
		result = require(module)
	end)

	-- Destroy in every path, including a syntax error inside require.
	pcall(function()
		module:Destroy()
	end)

	if not ranOk then
		-- A compile error never reaches the pcall inside the chunk, so it lands
		-- here with a line number counted from the top of the generated file.
		local message = tostring(requireErr):gsub(":(%d+):", function(digits)
			return ":" .. tostring((tonumber(digits) :: number) - PROLOGUE_LINES) .. ":"
		end)
		return nil, message
	end

	if type(result) ~= "table" then
		return nil, "harness returned an unexpected value — did the code redefine `return`?"
	end

	local lines: { string } = {}
	table.insert(lines, string.format("ran in %.2f ms", (result.elapsed or 0) * 1000))

	local captured = result.out or {}
	if #captured > 0 then
		table.insert(lines, "--- output ---")
		for index, line in ipairs(captured) do
			if index > MAX_OUTPUT_LINES then
				table.insert(lines, string.format("… %d more lines", #captured - MAX_OUTPUT_LINES))
				break
			end
			table.insert(lines, line)
		end
	end

	if result.ok then
		if result.ret ~= nil then
			table.insert(lines, "--- returned ---")
			table.insert(lines, describe(result.ret))
		end
	else
		local message = tostring(result.ret):gsub(":(%d+):", function(digits)
			return ":" .. tostring((tonumber(digits) :: number) - PROLOGUE_LINES) .. ":"
		end)
		table.insert(lines, "--- error ---")
		table.insert(lines, message)
	end

	return table.concat(lines, "\n"), nil
end

-- =============================================================================
-- catalog — search and load Roblox Free Models
-- =============================================================================
-- InsertService:GetFreeModelsAsync(searchText, pageNum) yields over HTTP and
-- returns a plain Lua table — NOT a CatalogPages Instance. Per the Roblox docs
-- the shape is "a single table wrapped in a table":
--   { [1] = { CurrentStartIndex, TotalCount, Results = {
--       { Name, AssetId, AssetVersionId, CreatorName }, ... } } }
-- See create.roblox.com/docs/reference/engine/classes/InsertService.
--
-- Those four fields are the whole row, and none of them says whether the asset
-- can actually be inserted. A raw result list is therefore useless twice over:
--   - entries that are not public-domain fail at load with "Asset is not trusted
--     for this place" — LoadAsset's documented rule is that the place owner must
--     own or have created the model (devforum.roblox.com/t/559187);
--   - the search backend is not the Toolbox UI's ranker, so it returns the
--     keyword-stuffed spam the UI filters out — searching "door" gives
--     "Door Door Door Door Door" from throwaway accounts
--     (devforum.roblox.com/t/1243668).
--
-- One extra call fixes both. MarketplaceService:GetProductInfo(id) carries
-- `IsPublicDomain` (the "free to take" flag), `AssetTypeId` (10 = Model) and
-- `Sales` (the take count for a free model). Filtering on the first two drops
-- the ids that are not free-to-take Models at all — and, because the call has
-- to succeed to be read, the ids that do not resolve to an asset. Ordering on
-- the third sinks the spam. One round-trip per result, issued in parallel, so
-- the search pays one yield rather than twenty-one.
--
-- What this does NOT buy is a guarantee that a surviving id will load.
-- IsPublicDomain describes the ASSET (it is free to take); whether this PLACE
-- may insert an asset it does not own is a separate switch — see
-- AllowInsertFreeAssets in catalogLoad. A perfectly good free model still fails
-- to load with that switch off, so the filter narrows the list, it does not
-- promise anything about the load.
--
-- Load goes through DataModel:GetObjects("rbxassetid://<id>"), NOT
-- InsertService:LoadAsset or AssetService:LoadAssetAsync. Both of those gate on
-- ownership: LoadAsset is capability LoadOwnedAsset and refuses anything the
-- place owner does not own, and LoadAssetAsync only lifts that when
-- AssetService.AllowInsertFreeAssets is true — a place setting that is off by
-- default, is RobloxScriptSecurity, and therefore can be neither read nor set
-- from a plugin. Left alone, every free model this tool finds fails to load.
-- GetObjects is PluginSecurity (non-plugin callers get "lacking capability
-- Plugin"), predates those checks and does not perform them, so it is the one
-- route a plugin actually has.
--
-- KNOWN TRADEOFF, chosen deliberately: LoadAssetAsync returns its model
-- sandboxed with no script capabilities, so untrusted scripts inside cannot
-- run. GetObjects has no such sandbox — scripts arrive live. Free models are the
-- classic backdoor vector and the ids here come from a spam-heavy search picked
-- over by a model, so the load reports its script count and says they are
-- unsandboxed. Auto-disabling them was rejected: it breaks every model whose
-- scripts are the reason you wanted it. Inspect before running.
--
-- GetObjects is also deprecated and does not yield — it blocks Studio for the
-- length of the fetch. Its yielding twin GetObjectsAsync is RobloxScriptSecurity
-- and unavailable to us. If a PluginSecurity replacement ever ships, or
-- AllowInsertFreeAssets becomes plugin-writable, this should move back to the
-- sandboxed path.
--
-- No pageNum. Pages 3 and above come back empty regardless of query — a
-- long-standing bug (devforum.roblox.com/t/2940192) — and page 2 after
-- public-domain filtering is thinner than simply asking a better question.
-- Advertising a knob that does nothing costs the model a turn to discover it.
--
-- Why nothing is loaded on search: the catalog returns dozens of plausible
-- results per query, and inserting each would fill Workspace with instances the
-- caller never inspected. The model is supposed to pick an id from the search
-- output and load it explicitly. That is the clobber this tool exists to avoid.
--
-- State discipline: search touches nothing — no instances, no cwd, no undo
-- recording, no table held between calls (the result is local to the call and
-- dropped on return). Load creates exactly one Model, wrapped in a single undo
-- recording, named Asset_<id> so two loads of the same asset sit side by side
-- rather than colliding on the asset's own (often generic) name.
local InsertService = game:GetService("InsertService")
local MarketplaceService = game:GetService("MarketplaceService")

-- A single page returns up to ~21 entries per the Roblox docs. The cap exists
-- because one unbounded search is enough to evict the rest of the conversation
-- from context — the same reason MAX_CAT_LINES exists.
local MAX_CATALOG_RESULTS = 20
-- Enum.AssetType.Model, compared as a number because GetProductInfo returns the
-- raw id rather than the enum.
local ASSET_TYPE_MODEL = 10
-- One slow GetProductInfo must not hang the whole tool call. Whatever has not
-- answered by then is dropped, which costs a result, not the search.
local PRODUCT_INFO_TIMEOUT = 15

-- GetProductInfo yields, so twenty serial calls cost twenty round-trips end to
-- end. Spawned, they overlap and the caller waits only for the slowest. Indexes
-- line up with `ids` so the result can be zipped back against the search rows;
-- a call that errors or times out simply leaves a hole, and a model we cannot
-- describe is a model we should not offer.
--
-- ponytail: polls with task.wait and re-fetches every search; swap the busy-wait
-- for a counting signal and memoise by assetId if searches ever get chatty.
local function productInfoBatch(ids: { number }): { [number]: any }
	local out: { [number]: any } = {}
	local pending = #ids
	for i, id in ipairs(ids) do
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset)
			end)
			if ok and type(info) == "table" then
				out[i] = info
			end
			pending -= 1
		end)
	end
	local deadline = os.clock() + PRODUCT_INFO_TIMEOUT
	while pending > 0 and os.clock() < deadline do
		task.wait()
	end
	return out
end

type FreeModel = { id: number, name: string, creator: string, sales: number }

-- Drop what will not load, order what remains. Pure and split out from
-- catalogSearch precisely so selfTest can exercise it without the network —
-- this function is what decides which ids the model is allowed to see, and a
-- regression either leaks unloadable ids or drops everything, both of which
-- look like "the catalog is down" from the outside.
local function rankFreeModels(results: { any }, infos: { [number]: any }): { FreeModel }
	local kept: { FreeModel } = {}
	for i, entry in ipairs(results) do
		local info = infos[i]
		-- AssetId comes back as a number per the docs; some entries have been
		-- seen to return string ids, so tonumber covers both.
		local id = type(entry) == "table" and tonumber(entry.AssetId) or nil
		if id and type(info) == "table" and info.IsPublicDomain == true
			and tonumber(info.AssetTypeId) == ASSET_TYPE_MODEL then
			local creator = entry.CreatorName
			if (creator == nil or creator == "") and type(info.Creator) == "table" then
				creator = info.Creator.Name
			end
			table.insert(kept, {
				id = id,
				name = tostring(info.Name or entry.Name or "(unnamed)"),
				creator = tostring(creator or ""),
				sales = tonumber(info.Sales) or 0,
			})
		end
	end
	-- Sales is the take count for a free model, and the only popularity signal
	-- GetProductInfo carries — there is no favourites field. Ties break on id
	-- because table.sort is not stable, and an order that shuffles between two
	-- identical searches reads as a changed result set.
	table.sort(kept, function(a, b)
		if a.sales ~= b.sales then
			return a.sales > b.sales
		end
		return a.id < b.id
	end)
	return kept
end

function Terminal:catalogSearch(query: string?): (string?, string?)
	if not query or query == "" then
		return nil, "catalog search requires a query"
	end

	-- Return type is a plain Lua table, NOT a CatalogPages Instance — the
	-- docs describe it as "a single table wrapped in a table":
	--   { [1] = { CurrentStartIndex, TotalCount, Results = { {Name, AssetId,
	--            AssetVersionId, CreatorName}, ... } } }
	-- So unpack the outer wrapper to reach the page object, then read .Results.
	-- pageNum is required and 0-indexed; 0 is the only page worth asking for.
	local raw: any
	local ok, err = pcall(function()
		raw = InsertService:GetFreeModelsAsync(query :: string, 0)
	end)
	if not ok then
		return nil, "GetFreeModelsAsync failed: " .. tostring(err)
	end
	if typeof(raw) ~= "table" then
		return nil, "GetFreeModelsAsync returned " .. typeof(raw) ..
			", expected a table (per docs: a table wrapped in a table)"
	end

	-- Unwrap: docs show the outer table has a single entry at [1] holding the
	-- page object. Be defensive — if the shape ever changes, surface it rather
	-- than silently returning "no models".
	local pageObj = raw[1]
	if type(pageObj) ~= "table" then
		return nil, "GetFreeModelsAsync returned an unexpected shape: outer " ..
			"table has no [1] entry of type table (got " .. type(pageObj) .. ")"
	end

	local results = pageObj.Results
	if type(results) ~= "table" or #results == 0 then
		return "no models found for " .. query, nil
	end

	-- Keep the index alignment even for malformed rows: rankFreeModels zips
	-- `infos[i]` against `results[i]`, so a skipped row would shift every id
	-- after it onto the wrong product info. A 0 here fails GetProductInfo,
	-- leaves a hole, and the row is dropped — which is the right answer anyway.
	local ids: { number } = {}
	for i, entry in ipairs(results) do
		ids[i] = (type(entry) == "table" and tonumber(entry.AssetId)) or 0
	end

	local kept = rankFreeModels(results, productInfoBatch(ids))
	if #kept == 0 then
		return string.format(
			"no loadable free models for %s — %d result(s) came back, none of them public-domain models",
			query, #results), nil
	end

	local shown = math.min(#kept, MAX_CATALOG_RESULTS)
	local lines: { string } = {}
	for i = 1, shown do
		local m = kept[i]
		-- Description is deliberately omitted even though GetProductInfo now
		-- carries it: free-model descriptions run to paragraphs of SEO, and
		-- twenty of them would cost more context than the search is worth.
		local creator = m.creator ~= "" and ("  by " .. m.creator) or ""
		table.insert(lines, string.format("%d. %s  [id %d]%s  (%d takes)",
			i, m.name, m.id, creator, m.sales))
	end

	local trailer = ""
	if #kept > shown then
		trailer = string.format("\n… %d more loadable results — refine the query",
			#kept - shown)
	end
	return table.concat(lines, "\n") .. trailer, nil
end

function Terminal:catalogLoad(assetId: number?, parentPath: string?): (string?, string?)
	if not assetId or assetId <= 0 then
		return nil, "catalog load requires a positive assetId"
	end

	local parent: Instance?
	if parentPath and parentPath ~= "" then
		local resolved, err = self:resolve(parentPath)
		if not resolved then
			return nil, "parent: " .. tostring(err)
		end
		parent = resolved
	else
		parent = game:GetService("Workspace")
	end

	local asset: Instance?
	local scriptCount = 0
	local _, loadErr = withUndo("Claude: load asset " .. tostring(assetId), function()
		-- GetObjects returns an ARRAY of roots, not one Instance: an asset is a
		-- list of top-level objects, and a Model is merely the common case of a
		-- list with one entry.
		local roots = game:GetObjects("rbxassetid://" .. tostring(assetId))
		if type(roots) ~= "table" or #roots == 0 then
			error("GetObjects returned nothing for asset " .. tostring(assetId), 2)
		end

		local a: Instance
		if #roots == 1 then
			-- One root is the overwhelmingly common shape. Use it directly so the
			-- result looks exactly like what the Toolbox would have inserted,
			-- rather than burying it under a wrapper nothing asked for.
			a = roots[1]
		else
			-- Several roots have to go somewhere, and returning them loose would
			-- scatter them across the parent with no way to undo-by-name or refer
			-- to the asset as one thing. A Folder is the cheapest container that
			-- adds no behaviour of its own.
			a = Instance.new("Folder")
			for _, r in ipairs(roots) do
				r.Parent = a
			end
		end

		-- Rename to Asset_<id> so the result is findable by name in the next
		-- breath, and so two loads of the same asset sit next to each other
		-- instead of colliding on the asset's own (often generic) name.
		a.Name = "Asset_" .. tostring(assetId)
		a.Parent = parent
		asset = a

		-- Count what came in. GetObjects does NOT sandbox (see the header note),
		-- so scripts arrive live and enabled — the caller is owed the number
		-- before it decides to run anything. Reporting beats auto-disabling:
		-- disabling would quietly break every model whose scripts are the point.
		for _, d in ipairs(a:GetDescendants()) do
			if d:IsA("LuaSourceContainer") then
				scriptCount += 1
			end
		end
	end)
	if loadErr then
		-- GetObjects bypasses the ownership checks entirely, so the "not trusted"
		-- / "not authorized" refusals that LoadAsset raised cannot occur here.
		-- What is left is a genuinely bad id: missing, moderated, or not an asset
		-- this account may fetch at all.
		local msg = tostring(loadErr)
		return nil, "GetObjects: " .. msg ..
			" — asset " .. tostring(assetId) ..
			" does not exist, has been moderated, or is not a model asset."
	end

	local a = asset :: Instance
	local scripts = ""
	if scriptCount > 0 then
		scripts = string.format(", %d script%s — NOT sandboxed, inspect before running",
			scriptCount, scriptCount == 1 and "" or "s")
	end
	return string.format("loaded asset %d as %s (%d children, %d descendants%s)",
		assetId, instancePath(a), #a:GetChildren(), #a:GetDescendants(), scripts), nil
end

-- =============================================================================
-- Shell facade
-- =============================================================================
-- Parsing and command dispatch live in Shell; this is the seam between "what a
-- line means" and "what it does to the DataModel". Required down here rather
-- than at the top because Shell's handlers call back into these methods, and
-- reading it in the order the code runs is easier than reading it alphabetically.
local Shell = require(script.Parent:WaitForChild("Shell"))

-- Run a `bash` line. `readOnly` is for /sh, where the human types the line
-- directly and mutations should stay Claude's — every write it makes carries an
-- undo recording.
function Terminal:shell(line: string?, readOnly: boolean?): string
	return Shell.run(self, line, readOnly)
end

-- Exported so /help can print the real command set instead of a hand-written
-- copy that goes stale the moment a handler is added.
Terminal.COMMANDS = Shell.COMMANDS

function Terminal.selfTest(): (boolean, string?)
	-- rankFreeModels is the only catalog logic that runs without the network,
	-- and it is the gate deciding which ids the model may see. Broken one way it
	-- offers assets that fail at load; broken the other it returns nothing and
	-- looks like an outage. Row 5 has no product info at all — the timeout case.
	local ranked = rankFreeModels({
		{ AssetId = 1, Name = "spam",    CreatorName = "a" },
		{ AssetId = 2, Name = "good",    CreatorName = "b" },
		{ AssetId = 3, Name = "private", CreatorName = "c" },
		{ AssetId = 4, Name = "decal",   CreatorName = "d" },
		{ AssetId = 5, Name = "timeout", CreatorName = "e" },
	}, {
		[1] = { IsPublicDomain = true,  AssetTypeId = 10, Sales = 3 },
		[2] = { IsPublicDomain = true,  AssetTypeId = 10, Sales = 99 },
		[3] = { IsPublicDomain = false, AssetTypeId = 10, Sales = 500 },
		[4] = { IsPublicDomain = true,  AssetTypeId = 13, Sales = 500 },
	})
	if #ranked ~= 2 then
		return false, string.format(
			"rankFreeModels kept %d of 5 (expected 2: private, non-Model and info-less rows must all drop)",
			#ranked)
	end
	if ranked[1].id ~= 2 or ranked[2].id ~= 1 then
		return false, string.format("rankFreeModels ordered %d,%d — expected 2,1 (sales descending)",
			ranked[1].id, ranked[2].id)
	end
	return Shell.selfTest(Terminal.new(game))
end

return Terminal
