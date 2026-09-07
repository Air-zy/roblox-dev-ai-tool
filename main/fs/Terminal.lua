--!optimize 2
-- Terminal.luau: the commands, as operations on the DataModel.
--
-- Every command here does one thing to the tree and returns text: list a
-- container, read a script, diff its properties against a default instance,
-- clone it, move it, execute Luau. None of them know about quoting, pipes or
-- argument parsing, that is Shell's half, and it calls into these.
--
-- What lives where:
--   fs/Fs         path resolution, .Source access, undo recording, glob matching
--   studio/Props  property names + default baselines, from the API dump
--   here          the commands themselves, as methods on a Terminal
--   fs/Shell      the command line: tokenizer, HANDLERS, pipelines, redirection
--   text/Regex    the BRE/ERE engine grep and sed compile through
--   agent/Tools   the tool registry; tools/ has one file per tool
--
-- Commands are reached through the `bash` tool. Everything carrying a Luau
-- payload: edit, multiedit, write, run, is a separate tool instead, because
-- routing source through shell quoting would eventually corrupt someone's script
-- and JSON parameters already solve escaping. The split is on payload, not risk.
--
-- Deliberately NOT here: separate ls/grep/glob tools duplicating the shell ones.
-- Two routes to one function means the model has to choose, every time, for no
-- gain: there are no pipes here for a structured variant to avoid.
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
local Props = require(script.Parent.Parent:WaitForChild("studio"):WaitForChild("Props"))
-- Only to tell a step-budget abort from a genuine fault when a grep throws.
local Regex = require(script.Parent.Parent:WaitForChild("text"):WaitForChild("Regex"))
local isScript        = Fs.isScript
local getSource       = Fs.getSource
local splitLines      = Fs.splitLines
local instancePath    = Fs.instancePath
local withUndo        = Fs.withUndo
local guardProtected  = Fs.guardProtected
local formatValue     = Fs.formatValue
local countOccurrences = Fs.countOccurrences
local splitPath       = Fs.splitPath
local displayName     = Fs.displayName
local syntaxErrors    = Fs.syntaxErrors

local Terminal = {}
Terminal.__index = Terminal

function Terminal.new(startInstance: Instance?)
	local self = setmetatable({}, Terminal)
	self.cwd = startInstance or game
	return self
end

-- The cwd is the only per-terminal state; path resolution itself is stateless.
function Terminal:resolve(path: string?): (Instance?, string?, string?)
	return Fs.resolve(self.cwd, path)
end

-- The destructive boundary. Every method that changes the DataModel routes its
-- path through here, so an ambiguous name is refused once rather than in each
-- of them -- and reading is left alone.
local function unique(self: any, path: string?, verb: string): (Instance?, string?, boolean)
	local inst, err, duplicate = self:resolve(path)
	if inst and duplicate then
		return nil, string.format("refusing to %s an ambiguous path: %s. `ls -i` and " ..
			"`find -inum` tell duplicates apart", verb, duplicate), true
	end
	return inst, err, false
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

-- Same discipline as run's output cap. An unbounded grep across a large place
-- returns thousands of lines and evicts the context that made the search worth
-- running: which is the real reason to want `| head`, and cheaper to fix here
-- than by growing a shell.
local MAX_RESULTS = 100

-- The single largest token sink in the whole harness: one `cat` of a 3000-line
-- module costs more context than every other command in a session combined.
-- Claude Code caps reads for the same reason. Paging is reachable now that
-- pipes exist: `head -n 1200 f | tail -n 200` gets an arbitrary window.
local MAX_CAT_LINES = 1000
-- Higher than MAX_LIST: a tree is structural, and the shape is most of its value.
local MAX_TREE = 1000

-- Commands

-- list
--
-- Returns ROWS, not rendered text. Sorting and column formatting moved to the
-- shell because that is where the flags live: -S and -t have to compare sizes
-- and observed mtimes, and neither survives being flattened to a string first.
-- Nothing is sorted here: `ls` sorts by name, and -U asks for exactly this
-- GetChildren() order, which a sort in here would have already destroyed.
export type LsRow = { inst: Instance, name: string }

function Terminal:ls(path: string?, filter: ((string) -> boolean)?): ({ LsRow }?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local rows: { LsRow } = {}
	for _, child in ipairs(target:GetChildren()) do
		-- Appends .luau to scripts so Claude knows they're editable files, and
		-- the filter runs on that displayed name so `ls *.luau` means what it
		-- looks like.
		local name = displayName(child)
		if not filter or filter(name) then
			rows[#rows + 1] = { inst = child, name = name }
		end
	end
	return rows, nil
end

-- cat: if script, return source. Otherwise, dump the properties that differ
-- from a default instance of the same class.
-- The third return is a NOTE about the text rather than part of it — currently
-- only the truncation line. The shell routes it to stderr's stand-in; see `note`
-- in Shell and runPipeline, which is what keeps it out of `| wc -l`.
function Terminal:cat(path: string?): (string?, string?, string?)
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
		-- every call: `head -640 | tail -80` for lines 560-640, and getting it
		-- wrong returns a plausible block from the wrong part of the file.
		--
		-- Returned as a THIRD value rather than glued to the text. The shell hands
		-- it to `note()`, which keeps it out of a pipe's data while still printing
		-- it: `cat big.luau | wc -l` now answers 1000 and says underneath that the
		-- file has 3182 lines. Appended, it was counted as a line — and stripping
		-- it instead would have hidden the truncation altogether, which is worse
		-- than mis-counting it by one.
		return table.concat(lines, "\n", 1, MAX_CAT_LINES), nil, string.format(
			"… TRUNCATED: %d of %d lines shown. Page the rest with " ..
			"`sed -n '%d,%dp' %s`, or grep for what you need.",
			MAX_CAT_LINES, #lines,
			MAX_CAT_LINES + 1, math.min(#lines, MAX_CAT_LINES * 2), instancePath(target))
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
	-- Tags and attributes are the two things about an instance that no property
	-- carries and `cat`'s property diff therefore cannot show. Both are omitted
	-- entirely when empty, which is the usual case: a line reading `Tags: (none)`
	-- on every stat is noise on the wire for the rare instance that has some.
	local tags = Fs.tags(target)
	if #tags > 0 then
		table.insert(lines, string.format("Tags: %s", table.concat(tags, ", ")))
	end
	local attributes = target:GetAttributes()
	local names = {}
	for name in pairs(attributes) do
		names[#names + 1] = name
	end
	if #names > 0 then
		table.sort(names)
		local rendered = {}
		for _, name in ipairs(names) do
			rendered[#rendered + 1] = string.format("%s=%s", name, formatValue(attributes[name]))
		end
		table.insert(lines, string.format("Attributes: %s", table.concat(rendered, ", ")))
	end
	-- No `Parent:` line: `Path:` above already ends with it.
	if not source then
		-- stat is metadata, the way it is everywhere else, and `cat` is what
		-- prints the property values. That split is obvious once you know it and
		-- invisible before, someone reading this output concluded the harness
		-- could not see Size or CFrame at all and went to the `run` tool for
		-- something `cat` does directly. One line is cheaper than that detour.
		table.insert(lines, "(property values: cat " .. instancePath(target) .. ")")
	end
	return table.concat(lines, "\n"), nil
end

-- head and tail live entirely in the shell now. They were implemented here for a
-- file operand and AGAIN there for piped input, which is how the two paths came
-- to disagree about -c and about a second operand; one implementation over
-- `inputs` cannot drift from itself.

-- find: walk a subtree and collect whatever `test` accepts.
--
-- The predicates are built by the SHELL, not here, because that is where find's
-- expression is parsed and because several of them (-size, -newer, -perm,
-- -inum) need Fs helpers Terminal has no other reason to reach for. What lives
-- here is the part that is genuinely about the DataModel: the walk, the depth
-- bounds and the cap.
--
-- Returns INSTANCES rather than formatted lines, so -delete has something to
-- destroy and -print can choose its own format.
export type FindOpts = { minDepth: number?, maxDepth: number? }

function Terminal:find(path: string?, test: (Instance) -> boolean, opts: FindOpts?): ({ Instance }?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	local o = opts or {}
	-- GNU find counts the starting point as depth 0 and tests it, which is what
	-- makes `find x -maxdepth 0` mean "just x".
	local minDepth = o.minDepth or 0
	local maxDepth = o.maxDepth or math.huge

	local results: { Instance } = {}
	local skipped = 0
	local function keep(inst: Instance)
		if #results >= MAX_RESULTS then
			skipped += 1
		else
			results[#results + 1] = inst
		end
	end

	if minDepth <= 0 and test(target) then
		keep(target)
	end
	-- A recursive walk rather than GetDescendants(), so -maxdepth can stop early
	-- instead of building the whole list and filtering it afterwards.
	--
	-- The cap is on RESULTS, not on the walk: past MAX_RESULTS it keeps going to
	-- count what it is not printing, which is what makes "… N more matches" a
	-- number rather than a shrug. On a large place that is the whole DataModel,
	-- so it breathes — see Fs.breather.
	local breathe = Fs.breather()
	local function walk(inst: Instance, depth: number)
		if depth > maxDepth then
			return
		end
		for _, child in ipairs(inst:GetChildren()) do
			breathe()
			if depth >= minDepth and test(child) then
				keep(child)
			end
			walk(child, depth + 1)
		end
	end
	walk(target, 1)

	local tagged: any = results
	if skipped > 0 then
		tagged.skipped = skipped
	end
	return results, nil
end

-- grep: search script sources.
--
-- Takes COMPILED programs, not pattern text, the dialect (BRE, ERE, literal)
-- was chosen by the caller from the flags, and compiling once here rather than
-- per line is what makes a real engine affordable across a whole place.
--
-- Returns STRUCTURED results, not text. It used to return `path:N: text` lines
-- joined into one string, which the shell then re-parsed three separate ways
-- splitting on "\n" to count for -c, regexing the path back out for -l, and
-- splitting on ":" again to group by file. Every one of those was undoing work
-- this function had just done, and none of them could carry a context line.
-- Formatting belongs to the caller; finding belongs here.
export type GrepMatch = { path: string, line: number, text: string, match: boolean }

-- `include`/`exclude` filter by the instance's DISPLAYED name, which is what
-- --include=*.luau is reaching for: the name `ls` printed. `.lua` matches the
-- same scripts, via Fs.matchesName.
export type GrepScope = { include: ((string) -> boolean)?, exclude: ((string) -> boolean)? }

function Terminal:grep(programs: { any }?, path: (string | { string })?, opts: Fs.GrepOpts?,
	scopeFilter: GrepScope?): ({ GrepMatch }?, string?)
	if not programs or #programs == 0 then
		return nil, "grep requires a pattern"
	end
	local roots = {}
	if type(path) == "table" then
		for _, name in ipairs(path) do
			local target, err = self:resolve(name)
			if not target then return nil, err end
			roots[#roots + 1] = target
		end
	else
		local target, err = self:resolve(path)
		if not target then return nil, err end
		roots[1] = target
	end
	local o: Fs.GrepOpts = opts or {}

	local filter = scopeFilter or {}
	local results: { GrepMatch } = {}
	local budget = MAX_RESULTS
	local skipped = 0
	-- What -c has to answer, which the hit list cannot: MAX_RESULTS caps what is
	-- EMITTED, not what is scanned, so counting hits reports how many fit rather
	-- than how many there are. Per file, because that is the shape `grep -rc`
	-- has everywhere else and one total cannot be split back apart.
	local counts: { { path: string, n: number } } = {}
	-- Include the target: `grep foo Main.luau` means search Main, and walking
	-- only descendants made that silently return "no matches". GetDescendants
	-- hands back a fresh table, so prepending to it is safe.
	local scope, seen, searched = {}, {}, {}
	for _, target in ipairs(roots) do
		local branch = target:GetDescendants()
		table.insert(branch, 1, target)
		for _, inst in ipairs(branch) do
			if not seen[inst] then scope[#scope + 1] = inst; seen[inst] = true end
		end
	end
	-- One pcall around the whole walk rather than one per line. The only thing
	-- that throws in here is the engine's step budget, and when a pattern is too
	-- expensive it is too expensive for every line, so the walk is abandoned and
	-- the pattern is named, instead of paying a pcall a hundred thousand times.
	-- Every script in the scope is read, and through the editor when one is open,
	-- so this is the most expensive walk here by some distance.
	local breathe = Fs.breather()
	local walkOk, walkErr = pcall(function()
		for _, inst in ipairs(scope) do
			breathe()
			local source = getSource(inst)
			if source and filter.include and not Fs.matchesName(inst, filter.include) then
				source = nil
			end
			if source and filter.exclude and Fs.matchesName(inst, filter.exclude) then
				source = nil
			end
			if source then
				searched[#searched + 1] = instancePath(inst)
				-- The cap counts MATCHES, not emitted lines, and is applied before
				-- the context window opens, otherwise `-C 5` would quietly return
				-- six times the budget and evict the context that made the search
				-- worth running, which is the one thing MAX_RESULTS exists to stop.
				local hits, taken, refused = Fs.grepLines(splitLines(source), programs, {
					invert = o.invert,
					only = o.only,
					before = o.before,
					after = o.after,
					-- Two caps, and the tighter one wins: `budget` is what is left of
					-- MAX_RESULTS across the whole walk, `o.limit` is grep's own -m
					-- per file. Taking budget alone silently discarded -m.
					limit = math.min(budget, o.limit or math.huge),
				})
				budget -= taken
				skipped += refused
				-- -m is the only cap that belongs in a count: it is grep's own, and
				-- it legitimately stops at N per file. `budget` is this harness's
				-- output cap and has no business changing a number.
				local total = math.min(taken + refused, o.limit or math.huge)
				if total > 0 then
					local instPath = instancePath(inst)
					counts[#counts + 1] = { path = instPath, n = total }
					for _, hit in ipairs(hits) do
						results[#results + 1] = {
							path = instPath, line = hit.line, text = hit.text, match = hit.match,
						}
					end
				end
			end
		end
	end)
	if not walkOk then
		if Regex.isBudget(walkErr) then
			return nil, "that pattern is too expensive to run — it backtracks more than " ..
				"this engine will spend on one line. Anchor it, or replace a nested " ..
				"quantifier like (a+)+ with a single one."
		end
		return nil, tostring(walkErr)
	end
	-- The cap trailer rides on the list rather than coming back as a third return
	-- value, which is the one a caller drops.
	local tagged: any = results
	if skipped > 0 then
		tagged.skipped = skipped
	end
	tagged.counts = counts
	tagged.searched = searched
	return results, nil
end

export type TreeOpts = {
	dirsOnly: boolean?,   -- -d: containers only, so the shape shows without the files
	fullPath: boolean?,   -- -f: print each entry's whole path
	classify: boolean?,   -- -F: "/" for containers, "*" for a script that will run
	dirsFirst: boolean?,  -- --dirsfirst
	include: string?,     -- -P: only entries matching this glob
	exclude: string?,     -- -I: skip entries matching this glob
}

function Terminal:tree(path: string?, depth: number?, opts: TreeOpts?): (string?, string?)
	local target, err = self:resolve(path)
	if not target then
		return nil, err
	end
	-- GNU tree is unlimited by default. Stopping at two levels with no marker
	-- rendered a populated directory as empty -- the one cap in this shell that
	-- did not name what it dropped (see BASH_FIDELITY section 5). Unlimited now,
	-- with a row cap that announces itself instead of a depth cap that did not.
	local maxDepth = depth or math.huge
	local skipped = 0
	local o = opts or {}
	-- -P filters what is PRINTED, not what is descended into: a matching entry
	-- three levels down is unreachable if the branches above it are pruned.
	local include = o.include and Fs.nameMatcher(o.include) or nil
	local exclude = o.exclude and Fs.nameMatcher(o.exclude) or nil

	local lines = {}
	local breathe = Fs.breather()
	local function walk(inst: Instance, prefix: string, d: number)
		if d > maxDepth then return end
		breathe()
		local children = inst:GetChildren()
		if o.dirsFirst then
			-- Stable within each group: containers by name, then scripts by name.
			table.sort(children, function(a, b)
				local da, db = not isScript(a), not isScript(b)
				if da ~= db then
					return da
				end
				return a.Name < b.Name
			end)
		end
		local shown = {}
		for _, child in ipairs(children) do
			local name = Fs.displayName(child)
			local keep = not (o.dirsOnly and isScript(child))
				and not (include and not include(name))
				and not (exclude and exclude(name))
			if keep then
				shown[#shown + 1] = child
			end
		end
		for index, child in ipairs(shown) do
			local last = index == #shown
			local branch = last and "└── " or "├── "
			local label = o.fullPath and instancePath(child)
				or (child.Name .. (isScript(child) and ".luau" or ""))
			if o.classify then
				label ..= isScript(child)
					and (Fs.modeBit(child, "x") and "*" or "")
					or "/"
			end
			if #lines >= MAX_TREE then
				skipped += 1
				continue
			end
			table.insert(lines, prefix .. branch .. label .. "  [" .. child.ClassName .. "]")
			local nextPrefix = prefix .. (last and "    " or "│   ")
			walk(child, nextPrefix, d + 1)
		end
	end

	table.insert(lines, instancePath(target))
	walk(target, "", 1)
	local text = table.concat(lines, "\n")
	if skipped > 0 then
		return text, nil, string.format(
			"… %d more entries (narrow it with `tree -L <depth>` or a subdirectory)", skipped)
	end
	return text, nil
end

-- Write commands
-- Mutation, undo recording and the protected-instance guard live in Fs; they
-- are aliased at the top of this file.

-- create: make a new instance of className under parentPath. Backs mkdir and
-- touch, which only differ in which className they pass in.
function Terminal:create(className: string, name: string?, parentPath: string?): (string?, string?)
	if not name or name == "" then
		return nil, "create requires a name"
	end
	local parent, err = unique(self, parentPath, "create in")
	if not parent then return nil, err end

	local existing = parent:FindFirstChild(name)
	if existing then
		return string.format("%s already exists", instancePath(existing)), nil
	end

	local created, createErr = withUndo("agent: create " .. name, function()
		local inst = Instance.new(className)
		inst.Name = name
		inst.Parent = parent
		return inst
	end)
	if createErr then return nil, createErr end
	return string.format("created %s [%s]", instancePath(created :: Instance), className), nil
end

-- The script at `path`, created if it is not there yet. Both ways of writing a
-- new file go through this: the shell's `> path` and the `write` tool. They used
-- to be two copies of the same six lines, which is how `write` came to be the
-- one that failed on a path `>` would have created.
--
-- The PARENT must already exist. `mkdir -p` is one command away, and
-- materialising folders silently is how a typo'd path becomes a new tree
-- instead of an error.
function Terminal:ensureScript(path: string): (Instance?, string?)
	local existing = self:resolve(path)
	if existing then
		return existing, nil
	end
	local parentPath, leaf = splitPath(path)
	local parent, parentErr = self:resolve(parentPath)
	if not parent then
		-- The policy above, carried to the one call that hit it. Bare, this came
		-- back as `no child named "my" in /Workspace`, which is true and answers a
		-- different question than the one being asked: the caller wanted a file
		-- created, and nothing said the missing part was the FOLDER or that one
		-- command makes it. bash is no more helpful here ("No such file or
		-- directory"), but bash is not the standard the rest of this file is held
		-- to. Named rather than done, because auto-creating is how a typo'd path
		-- becomes a new tree instead of an error.
		--
		-- parentPath cannot be nil on this branch: splitPath only returns nil when
		-- the path holds no "/", and resolve(nil) is the cwd, which never fails.
		-- tostring anyway, so a future change to either cannot turn this into a
		-- format error thrown from inside an error path.
		return nil, string.format("%s — `mkdir -p %s` first, then write %s",
			tostring(parentErr), tostring(parentPath), path)
	end
	local class, name = Fs.classFor(leaf)
	return withUndo("agent: create " .. name, function()
		local inst = Instance.new(class)
		inst.Name = name
		inst.Parent = parent
		return inst
	end)
end

-- Append a syntax check to a write that has ALREADY landed. Never a reason to
-- reject one.
--
-- Appending cannot break anything: a false positive costs the model one line of
-- noise, where refusing the write on one would make a file unwritable with no
-- way around it from the agent's side. It also leaves a deliberately broken
-- intermediate state legal, which a sequence of edits sometimes needs before the
-- last one closes it back up.
--
-- Both write paths route through here, and they are the only two that change
-- source: `sed -i` writes through :write, and cp/mv/rm never touch it.
-- Skipped for a file that is not Luau. A cloned README lands in a ModuleScript
-- because .Source is the only place text lives here, and running the parser over
-- markdown reports a syntax error on every write of it — true, useless, and
-- indistinguishable from one that matters.
local function withSyntax(message: string, source: string, name: string?): string
	if name and Fs.carriesExtension(name) then
		return message
	end
	local bad = syntaxErrors(source)
	return bad and (message .. "\nsyntax error:\n" .. bad) or message
end

-- write: replace a script's entire source, creating the script if it is missing.
function Terminal:write(path: string?, content: string?): (string?, string?)
	if content == nil then
		return nil, "write requires content"
	end
	local target, err, refused = unique(self, path, "write")
	local created = false
	if not target and not refused and path and path ~= "" then
		target, err = self:ensureScript(path)
		created = target ~= nil
	end
	if not target then return nil, err end
	if not isScript(target) then
		return nil, "not a script: " .. instancePath(target)
	end

	-- withUndo stays wrapped around the editor path even though the editor keeps
	-- its own undo stack. It fails SAFE either way: if UpdateSourceAsync already
	-- registers a waypoint, TryBeginRecording returns nil for the nested call and
	-- this adds nothing; if it does not, this recording is the only thing making
	-- the edit reversible. Losing undo on a write is data loss, so the coarser
	-- recording is the cheaper mistake.
	local _, writeErr = withUndo("agent: write " .. target.Name, function()
		local sourceErr = Fs.writeSource(target, content :: string)
		if sourceErr then
			error(sourceErr, 0)
		end
	end)
	if writeErr then return nil, writeErr end
	-- Changing the source moves nothing, so DescendantAdded never fires for it
	-- and the observed-mtime journal would miss the most common edit there is.
	Fs.touch(target)

	return withSyntax(string.format("%s %s (%d lines)", created and "created" or "wrote",
		instancePath(target),
		#splitLines(Fs.normaliseNewlines(content :: string))), content :: string,
		target.Name), nil
end

-- multiedit: apply substring replacements in order, all or nothing.
--
-- Each old_string must be unique in the source AS OF ITS TURN, so a later edit
-- can legitimately target text an earlier one introduced. Every edit is applied
-- to an in-memory copy and the whole batch is validated before a single
-- assignment lands, that is what lets a failure leave the script byte-identical
-- and the retry safe, instead of half-applied with no way back.
--
-- One withUndo for the batch, so Ctrl+Z reverses the whole thing rather than
-- walking back through it one replacement at a time.
function Terminal:multiedit(path: string?, edits: { any }?): (string?, string?)
	if type(edits) ~= "table" or #edits == 0 then
		return nil, "edits must be a non-empty array of { old_string, new_string }"
	end
	local target, err = unique(self, path, "edit")
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

	-- Same undo reasoning as :write above.
	local _, writeErr = withUndo("agent: edit " .. target.Name, function()
		local sourceErr = Fs.writeSource(target, updated)
		if sourceErr then
			error(sourceErr, 0)
		end
	end)
	if writeErr then return nil, writeErr end
	Fs.touch(target)

	return withSyntax(string.format("edited %s (%d changes, -%d/+%d lines)",
		instancePath(target), #edits, removed, added), updated, target.Name), nil
end

-- edit: the single-replacement case. Same semantics, same undo record.
function Terminal:edit(path: string?, old: string?, new: string?): (string?, string?)
	return self:multiedit(path, { { old_string = old, new_string = new } })
end

-- Resolve the final entry before changing anything. Scripts are files even
-- though Roblox permits children beneath them; -T names an entry directly.
local function copyChild(parent: Instance, source: Instance): (Instance?, string?)
	local found = nil
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == source.Name or displayName(child) == displayName(source) then
			if found then return nil, "ambiguous destination, duplicate siblings named " .. source.Name end
			found = child
		end
	end
	return found, nil
end

local function destinationEntry(self: any, source: Instance, destination: string,
	opts: any): (Instance?, string?, Instance?, string?)
	local existing = self:resolve(destination)
	if existing and not isScript(existing) and not opts.noTargetDirectory then
		local child, err = copyChild(existing, source)
		return existing, source.Name, child, err
	end
	if destination:sub(-1) == "/" and (not existing or isScript(existing)) then
		return nil, nil, nil, "destination is not a directory: " .. destination
	end
	if existing then
		return existing.Parent, existing.Name, existing, nil
	end
	local parentPath, leaf = splitPath(destination)
	if leaf == "" or leaf == "." or leaf == ".." then
		return nil, nil, nil, "invalid destination: " .. destination
	end
	local parent, err = self:resolve(parentPath)
	return parent, Fs.stripScriptSuffix(leaf) or leaf, nil, err
end

-- rm destroys the entry itself, irrespective of whether it also has children.
function Terminal:remove(path: string?): (string?, string?)
	if not path or path == "" then return nil, "rm requires a path" end
	local target, err = unique(self, path, "remove")
	if not target then return nil, err end
	local protected = guardProtected(target)
	if protected then return nil, protected end
	if self.cwd == target or self.cwd:IsDescendantOf(target) then
		return nil, "cd out of " .. instancePath(target) .. " first, rm destroys it"
	end
	-- Unparented rather than Destroy()d: Destroy locks the Parent property, and
	-- undo history is a stream of property changes, so the record could not be
	-- reapplied -- Studio warned "the Parent property is locked" and restored
	-- nothing, then the NEXT undo reverted something older instead. The subtree
	-- stays alive on the history entry, which is what makes the delete
	-- reversible; it is collected when the entry falls off the stack.
	local fullPath, descendants = instancePath(target), #target:GetDescendants()
	local _, removeErr = withUndo("agent: rm " .. target.Name, function()
		target.Parent = nil
	end)
	if removeErr then return nil, removeErr end
	return string.format("removed %s (%d descendants)", fullPath, descendants), nil
end

-- Copy plans are validated as a whole before the undo recording starts. Merging
-- directories must never create duplicate siblings or remove unrelated entries.
local function transfer(self: any, moving: boolean, path: string?, destination: string?,
	opts: any): (string?, string?)
	local cmd = moving and "mv" or "cp"
	if not path or path == "" or not destination or destination == "" then
		return nil, cmd .. " requires a source path and a destination path"
	end
	local source, err = unique(self, path, cmd)
	if not source then return nil, err end
	if source == game then return nil, "refusing to " .. cmd .. " /" end
	if moving then
		local protected = guardProtected(source)
		if protected then return nil, protected end
	elseif not isScript(source) and not opts.recursive then
		return nil, instancePath(source) .. " is a directory — use cp -r"
	end
	local parent, name, existing, destErr = destinationEntry(self, source, destination, opts)
	if destErr then return nil, destErr end
	if not parent then return nil, "refusing to replace /" end
	if parent == game then return nil, "cannot create or replace a service at /" end
	if parent == source or parent:IsDescendantOf(source) then
		return nil, "refusing to " .. cmd .. " an instance into itself"
	end

	local operations, claims = {}, {}
	local function plan(from: Instance, into: Instance, leaf: string, old: Instance?): string?
		-- Duplicate names may already exist in a place. Refuse an ambiguous write
		-- instead of choosing whichever FindFirstChild happens to return.
		local matches = 0
		for _, child in ipairs(into:GetChildren()) do
			if child.Name == leaf or displayName(child) == displayName(from) and child == old then
				matches += 1
			end
		end
		if matches > 1 then return "ambiguous destination, duplicate siblings named " .. leaf end
		claims[into] = claims[into] or {}
		if claims[into][leaf] then return "ambiguous source, duplicate siblings named " .. leaf end
		claims[into][leaf] = true
		if old then
			if old == from then return "source and destination are the same file: " .. instancePath(from) end
			if isScript(old) ~= isScript(from) then
				return "cannot overwrite a " .. (isScript(old) and "file with a directory" or "directory with a file")
			end
			if opts.noClobber and (isScript(old) or moving) then return nil end
			local protected = guardProtected(old)
			if protected then return protected end
			if old == self.cwd or self.cwd:IsDescendantOf(old) then
				return "cd out of " .. instancePath(old) .. " first, " .. cmd .. " would replace it"
			end
			if from:IsDescendantOf(old) then return "refusing to overwrite an ancestor of the source" end
			if not moving then
				if isScript(from) then
					-- Overwriting a file changes its contents, not its class, identity,
					-- or unrelated children. In particular, copying a Script onto a
					-- ModuleScript must not turn the destination into a running Script.
					operations[#operations + 1] = { from = from, into = into, name = leaf, old = old,
						text = getSource(from), previous = getSource(old) }
				end
				for _, child in ipairs(from:GetChildren()) do
					local previous, lookupErr = copyChild(old, child)
					if lookupErr then return lookupErr end
					local childErr = plan(child, old, child.Name, previous)
					if childErr then return childErr end
				end
				return nil
			end
			if moving and not isScript(old) and #old:GetChildren() > 0 then
				return "destination directory is not empty: " .. instancePath(old)
			end
		end
		if not moving then
			-- Clone skips non-Archivable descendants, which would silently produce
			-- an incomplete package. Check the entire branch, not only its root.
			local branch = { from }
			for _, child in ipairs(from:GetDescendants()) do branch[#branch + 1] = child end
			for _, item in ipairs(branch) do
				if not item.Archivable then return instancePath(item) .. " is not Archivable and cannot be cloned" end
				local names, rawNames = {}, {}
				for _, child in ipairs(item:GetChildren()) do
					local key = displayName(child)
					if names[key] or rawNames[child.Name] then return "ambiguous source, duplicate children named " .. key end
					names[key], rawNames[child.Name] = true, true
				end
			end
		end
		operations[#operations + 1] = { from = from, into = into, name = leaf, old = old }
		return nil
	end
	local planErr = plan(source, parent, name :: string, existing)
	if planErr then return nil, planErr end
	if #operations == 0 then return "", nil end

	-- Carry editor buffers for every copied script. Child names were validated
	-- above, so lookup is unambiguous and does not assume Clone preserves order.
	local function carryBuffers(from: Instance, clone: Instance)
		local sourceText = getSource(from)
		if sourceText and getSource(clone) ~= sourceText then
			local writeErr = Fs.writeSource(clone, sourceText)
			if writeErr then error(writeErr, 0) end
		end
		for _, child in ipairs(from:GetChildren()) do
			local peer = clone:FindFirstChild(child.Name)
			if not peer then error("Clone omitted " .. child.Name, 0) end
			carryBuffers(child, peer)
		end
	end
	local _, transferErr = withUndo("agent: " .. cmd .. " " .. source.Name, function()
		-- Prepare every clone before replacing an existing entry. On a failed
		-- source write, originals still exist and the temporary copies are removed.
		local prepared = {}
		local preparedOk, prepareErr = pcall(function()
			if not moving then
				for _, op in ipairs(operations) do
					if op.text ~= nil then continue end
					local clone = op.from:Clone()
					if not clone then error("Clone returned no instance", 0) end
					prepared[#prepared + 1] = clone
					op.clone = clone
					clone.Name = op.name
					clone.Parent = op.into
					carryBuffers(op.from, clone)
				end
				for _, op in ipairs(operations) do
					if op.text ~= nil then
						op.written = true
						local writeErr = Fs.writeSource(op.old, op.text)
						if writeErr then error(writeErr, 0) end
						Fs.touch(op.old)
					end
				end
			end
		end)
		if not preparedOk then
			for _, op in ipairs(operations) do
				if op.written then
					local restoreErr = Fs.writeSource(op.old, op.previous)
					if restoreErr then prepareErr = tostring(prepareErr) .. "; restoring " .. op.name .. ": " .. restoreErr end
				end
			end
			for _, clone in ipairs(prepared) do clone:Destroy() end
			error(prepareErr, 0)
		end
		for _, op in ipairs(operations) do
			if moving then
				op.from.Name = op.name
				op.from.Parent = op.into
			end
			-- Unparented, not destroyed, for the same reason rm is: overwriting a
			-- destination has to be reversible too.
			if op.old and op.text == nil then op.old.Parent = nil end
		end
	end)
	if transferErr then return nil, transferErr end
	local last = operations[#operations]
	local result = moving and source or last.clone or last.old
	return (moving and "moved to " or "copied to ") .. instancePath(result), nil
end

function Terminal:move(path: string?, destination: string?, opts: any?): (string?, string?)
	return transfer(self, true, path, destination, opts or {})
end

function Terminal:copy(path: string?, destination: string?, opts: any?): (string?, string?)
	return transfer(self, false, path, destination, opts or {})
end

-- reload: swap a module for a fresh clone of itself.
--
-- require() caches per Instance and never re-runs a module, so one edited after
-- it was first required keeps handing back the old value for the rest of the
-- session. A clone is a different Instance and therefore a different cache key:
-- put it where the original was, and every later require of that path resolves
-- to something that has never been run. Clone() takes descendants, so a package
-- reloads whole.
--
-- Only what is listed. A module that merely REQUIRES one of these still holds
-- the old copy's table, so list the dependents too, or their common parent.
function Terminal:reload(paths: { string }?): (string?, string?)
	if type(paths) ~= "table" or #paths == 0 then
		return nil, "reload requires at least one path"
	end
	local done: { string } = {}
	for index, path in ipairs(paths) do
		if type(path) ~= "string" or path == "" then
			return nil, string.format("path %d must be a non-empty string", index)
		end
		-- Resolved one at a time rather than up front: reloading a parent
		-- destroys the children named later in the list, and by then the path
		-- points at the fresh copy, which is the one to swap.
		local target, err = self:resolve(path)
		if not target then return nil, err end
		if not target:IsA("ModuleScript") then
			return nil, "not a module, nothing else is required: " .. instancePath(target)
		end
		local parent = target.Parent
		if not parent then
			return nil, "not in the tree: " .. instancePath(target)
		end
		-- Clone() returns nil rather than throwing here, so without this the
		-- failure surfaces as a null-index further down.
		if not target.Archivable then
			return nil, string.format("%s is not Archivable and cannot be cloned", instancePath(target))
		end
		-- The original is destroyed, and a cwd inside it would become a detached
		-- instance every later path resolves against. Rojo's init convention
		-- makes a ModuleScript with children ordinary, so this is reachable.
		if self.cwd == target or self.cwd:IsDescendantOf(target) then
			return nil, "cd out of " .. instancePath(target) .. " first, reload destroys it"
		end
		local full = instancePath(target)
		-- getSource, not the .Source that Clone() copies: a script open in the
		-- editor with unsaved edits has two texts, and .Source is the one the
		-- user is not looking at. Destroying the original closes that tab, so
		-- reading the buffer here is what keeps those edits.
		local source = getSource(target)
		local _, swapErr = withUndo("agent: reload " .. target.Name, function()
			local fresh = target:Clone()
			-- Clone() has ALREADY copied .Source. This assignment exists only to
			-- carry the editor's unsaved buffer, which .Source does not reflect,
			-- so it is skipped when the two already agree.
			--
			-- Not merely a saved call: the .Source setter refuses at 200,000
			-- characters, so re-assigning text it had just copied was enough to
			-- make `reload` fail outright on any module past that. fs/Shell is,
			-- which meant reloading the shell after editing it was impossible.
			-- Parented BEFORE the write so it can go through the script editor,
			-- which is the only path that accepts a very long source. An unparented
			-- clone has no document to open.
			fresh.Parent = parent
			if source and (fresh :: any).Source ~= source then
				local sourceErr = Fs.writeSource(fresh, source)
				if sourceErr then
					fresh:Destroy()
					error(sourceErr, 0)
				end
			end
			target:Destroy()
		end)
		if swapErr then return nil, swapErr end
		done[#done + 1] = full
	end
	return "reloaded:\n  " .. table.concat(done, "\n  "), nil
end

-- Shell facade
-- Parsing and command dispatch live in Shell; this is the seam between "what a
-- line means" and "what it does to the DataModel". Required down here rather
-- than at the top because Shell's handlers call back into these methods, and
-- reading it in the order the code runs is easier than reading it alphabetically.
local Shell = require(script.Parent:WaitForChild("Shell"))

-- Run a `bash` line.
-- run and catalog live in studio/, no shell command reaches either, so they
-- were sharing a file with code they have nothing to do with. Terminal keeps
-- the method names so tools/ and the self-test are unchanged.
--
-- REQUIRED ON FIRST USE, not at the top. Loading Exec calls GetService for
-- ServerStorage and LogService, and loading Catalog calls it for InsertService
-- and MarketplaceService — four services a session that never executes a script
-- or loads a model has no reason to touch, and `run` is off by default. The
-- WaitForChild stays up here so the deferred require is a plain lookup and
-- cannot yield inside a tool call.
local studioFolder = script.Parent.Parent:WaitForChild("studio")
local execScript = studioFolder:WaitForChild("Exec")
local catalogScript = studioFolder:WaitForChild("Catalog")

local execModule: any = nil
local catalogModule: any = nil
-- Held HERE rather than forwarded straight to Exec, which is what let the
-- require move at all: main sets the guard while the widget is opening, so an
-- alias to Exec.setRunGuard would have loaded Exec at startup — exactly the
-- thing being avoided — for a value Exec does not read until something runs.
local runGuard: (() -> boolean)? = nil

local function exec(): any
	if not execModule then
		execModule = require(execScript)
		if runGuard then
			execModule.setRunGuard(runGuard)
		end
	end
	return execModule
end

local function catalog(): any
	if not catalogModule then
		catalogModule = require(catalogScript)
	end
	return catalogModule
end

-- Set before Exec exists in the usual case, and after it in the self-test's, so
-- both directions have to work: store it, and push it across if the module is
-- already loaded.
function Terminal.setRunGuard(guard: () -> boolean)
	runGuard = guard
	if execModule then
		execModule.setRunGuard(guard)
	end
end

function Terminal:run(path: string?): (string?, string?)
	return exec().run(self, path)
end

function Terminal:catalogSearch(query: string?): (string?, string?)
	return catalog().search(self, query)
end

function Terminal:catalogLoad(assetId: number?, parentPath: string?): (string?, string?)
	return catalog().load(self, assetId, parentPath)
end

function Terminal:shell(line: string?): string
	return Shell.run(self, line)
end

-- Exported so /help can print the real command set instead of a hand-written
-- copy that goes stale the moment a handler is added.
Terminal.COMMANDS = Shell.COMMANDS

function Terminal.selfTest(): (boolean, string?)
	-- The pattern engine, first: grep, sed and find all sit on it, so a failure
	-- here explains every one of their failures and should be reported instead of
	-- them. It needs no DataModel, which is why it can run before anything else.
	local regexOk, regexErr = Regex.selfTest()
	if not regexOk then
		return false, "regex engine: " .. tostring(regexErr)
	end

	-- reload leaves a DIFFERENT instance at the path, carrying the same source.
	-- That difference is the whole mechanism, since the require cache is keyed
	-- on the instance; that a fresh key actually re-runs the module is Exec's
	-- 1/1/2 probe. Detached fixture, so nothing lands in the open place.
	local fixture = Instance.new("Folder")
	local module = Instance.new("ModuleScript")
	module.Name = "ReloadProbe"
	module.Source = "return 1"
	module.Parent = fixture
	local reloadTerm = Terminal.new(fixture)
	local _, reloadErr = reloadTerm:reload({ "ReloadProbe" })
	if reloadErr then
		return false, "reload failed: " .. tostring(reloadErr)
	end
	local fresh = fixture:FindFirstChild("ReloadProbe")
	if not fresh or fresh == module then
		return false, "reload left the same instance in place, so the cache key is unchanged"
	end
	if (fresh :: any).Source ~= "return 1" then
		return false, "reload lost the module's source"
	end
	if module.Parent ~= nil then
		return false, "reload left the old instance in the tree"
	end
	-- A path that is not a module is refused rather than swapped: Folders are
	-- never required, so replacing one would be churn for nothing.
	if reloadTerm:reload({ "/" }) then
		return false, "reload accepted something that is not a module"
	end

	-- run and catalog test themselves; this only chains them. Testing them is
	-- also what LOADS them now, which is the right way round: /selftest is a
	-- deliberate act, where opening the widget was not.
	local execOk, execErr = exec().selfTest(Terminal.new(game))
	if not execOk then return false, execErr end

	local catOk, catErr = catalog().selfTest()
	if not catOk then return false, catErr end

	return Shell.selfTest(Terminal.new(game))
end

return Terminal
