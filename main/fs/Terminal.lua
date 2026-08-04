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
				name = string.format("%-32s [%s]  %d children", name, child.ClassName, #child:GetChildren())
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
		return string.format("%s\n… TRUNCATED: %d of %d lines shown. Page the rest with " ..
			"`head -n <end> %s | tail -n <count>`, or grep for what you need.",
			table.concat(lines, "\n", 1, MAX_CAT_LINES), MAX_CAT_LINES, #lines,
			instancePath(target)), nil
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
	if target.Parent then
		table.insert(lines, string.format("Parent: %s", target.Parent.Name))
	end
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

-- wc: line count (scripts) or children count (other instances)
function Terminal:wc(path: string?): (string?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local source = getSource(target)
	if source then
		return string.format("%d lines", #splitLines(source)), nil
	end
	return string.format("%d children", #target:GetChildren()), nil
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
function Terminal:grep(pattern: string?, path: string?, usePattern: boolean?): (string?, string?)
	if not pattern or pattern == "" then
		return nil, "grep requires a pattern"
	end
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end

	local needle = pattern:lower()
	if usePattern then
		-- Validate once. A malformed pattern throws from find(), and checking
		-- per line would mean a pcall for every line of every script in scope.
		local ok = pcall(string.find, "", needle)
		if not ok then
			return nil, "not a valid Lua pattern: " .. pattern
		end
	end

	local results = {}
	-- Include the target: `grep foo Main.luau` means search Main, and walking
	-- only descendants made that silently return "no matches". GetDescendants
	-- hands back a fresh table, so prepending to it is safe.
	local scope = target:GetDescendants()
	table.insert(scope, 1, target)
	for _, inst in ipairs(scope) do
		local source = getSource(inst)
		if source then
			for lineNum, line in ipairs(splitLines(source)) do
				local lowered = line:lower()
				local hit
				if usePattern then
					hit = lowered:find(needle) ~= nil
				else
					hit = lowered:find(needle, 1, true) ~= nil
				end
				if hit then
					table.insert(results, string.format("%s:%d: %s", instancePath(inst), lineNum, line))
				end
			end
		end
	end
	if #results == 0 then
		return "no matches", nil
	end
	return capped(results, "matching lines"), nil
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
-- InsertService:LoadAsset(assetId) yields again and returns a Model containing
-- the asset's contents. Both calls are network-bound, so neither happens unless
-- the caller asks — search returns TEXT only, load inserts ONE Model under a
-- parent the caller names.
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

-- A single page returns up to ~21 entries per the Roblox docs. The cap exists
-- because one unbounded search is enough to evict the rest of the conversation
-- from context — the same reason MAX_CAT_LINES exists. If page 1 misses, the
-- query is the problem, not the page count.
local MAX_CATALOG_RESULTS = 20

function Terminal:catalogSearch(query: string?, pageNum: number?): (string?, string?)
	if not query or query == "" then
		return nil, "catalog search requires a query"
	end
	-- GetFreeModelsAsync(searchText, pageNum) is the signature per the Roblox
	-- docs (create.roblox.com/docs/reference/engine/classes/InsertService).
	-- `pageNum` is required AND 0-indexed: the docs example calls
	-- `GetFreeModelsAsync("Cats", 0)` with the comment "Search for Cats on
	-- Page 1". Expose 1-indexed pages to the caller (matches intuition), and
	-- convert internally.
	local page = math.max(1, math.floor(pageNum or 1)) - 1

	-- Return type is a plain Lua table, NOT a CatalogPages Instance — the
	-- docs describe it as "a single table wrapped in a table":
	--   { [1] = { CurrentStartIndex, TotalCount, Results = { {Name, AssetId,
	--            AssetVersionId, CreatorName}, ... } } }
	-- So unpack the outer wrapper to reach the page object, then read .Results.
	local raw: any
	local ok, err = pcall(function()
		raw = InsertService:GetFreeModelsAsync(query :: string, page)
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

	local shown = math.min(#results, MAX_CATALOG_RESULTS)
	local lines: { string } = {}
	for i = 1, shown do
		local entry = results[i]
		if type(entry) == "table" then
			local name = tostring(entry.Name or "(unnamed)")
			-- AssetId comes back as a number per the docs; some entries have
			-- been seen to return string ids, so tonumber covers both.
			local id = tonumber(entry.AssetId) or 0
			-- Free Model entries do NOT include Description in the catalog
			-- response (only Name, AssetId, AssetVersionId, CreatorName).
			-- Showing "(no description)" would be noise on every line; just
			-- omit it.
			local creator = ""
			if entry.CreatorName ~= nil and entry.CreatorName ~= "" then
				creator = "  by " .. tostring(entry.CreatorName)
			end
			table.insert(lines, string.format("%d. %s  [id %d]%s",
				i, name, id, creator))
		end
	end

	local trailer = ""
	if #results > shown then
		trailer = string.format("\n… %d more on this page — refine the query or pass pageNum",
			#results - shown)
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
	local _, loadErr = withUndo("Claude: load asset " .. tostring(assetId), function()
		asset = InsertService:LoadAsset(assetId :: number)
		if not asset then
			error("LoadAsset returned nil", 2)
		end
		-- Hoist the cast once: a line starting with `(` is ambiguous to Luau
		-- (could be an argument list continuing the previous statement), so
		-- assigning through `(asset :: Instance).Name = ...` twice in a row
		-- trips the parser. A local sidesteps it and reads better.
		local a = asset :: Instance
		-- LoadAsset returns a Model named after the asset, which is often a
		-- generic "Model". Rename to Asset_<id> so the result is findable by
		-- name in the next breath, and so two loads of the same asset sit
		-- next to each other instead of colliding on the asset's own name.
		a.Name = "Asset_" .. tostring(assetId)
		a.Parent = parent
	end)
	if loadErr then
		-- LoadAsset refuses non-owned assets that aren't catalog free models:
		--   "Asset is not trusted for this place"  → asset isn't a catalog free
		--                                            model and isn't owned by you
		--   "User is not authorized to access Asset" → asset doesn't exist, is
		--                                            private, or has been moderated
		-- Catalog free models (the IDs `catalog search` returns) load fine; the
		-- failures come from guessing IDs. Say so rather than just rethrowing.
		local msg = tostring(loadErr)
		if msg:find("not trusted") then
			return nil, "LoadAsset: " .. msg ..
				" — this asset is not a catalog free model. Run `catalog search <query>`" ..
				" and load one of the returned IDs."
		elseif msg:find("not authorized") then
			return nil, "LoadAsset: " .. msg ..
				" — asset " .. tostring(assetId) ..
				" does not exist, is private, or has been moderated."
		end
		return nil, "LoadAsset: " .. msg
	end

	local a = asset :: Instance
	return string.format("loaded asset %d as %s (%d children, %d descendants)",
		assetId, instancePath(a), #a:GetChildren(), #a:GetDescendants()), nil
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
	return Shell.selfTest(Terminal.new(game))
end

return Terminal
