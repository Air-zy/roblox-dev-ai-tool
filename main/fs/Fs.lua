--!optimize 2
-- Fs.luau — the DataModel-as-filesystem primitives.
--
-- Everything here answers one of two questions: "which Instance does this path
-- mean?" and "how do I read or change it safely?". No commands, no shell, no
-- tool definitions — those sit on top of this. Split out of Terminal because
-- every layer above needs `resolve`, and a file that owns the path model plus
-- the shell plus the tool registry has no seam to test or extend at.
--
-- Path semantics:
--   /              = game
--   /Workspace     = game:GetService("Workspace")
--   .              = the base instance
--   ..             = parent
--   foo            = child named "foo" of the base
--   /Workspace/Parts/Brick  = absolute path

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Fs = {}

-- =============================================================================
-- Scripts and source
-- =============================================================================
-- True for anything with a readable .Source.
local function isScript(inst: Instance): boolean
	return inst:IsA("Script") or inst:IsA("LocalScript") or inst:IsA("ModuleScript")
end
Fs.isScript = isScript

-- Safely read .Source. nil when the instance has none.
local function getSource(inst: Instance): string?
	if not isScript(inst) then return nil end
	local ok, source = pcall(function() return (inst :: any).Source end)
	if ok and type(source) == "string" then
		return source
	end
	return nil
end
Fs.getSource = getSource

-- Splitting with gmatch("[^\n]*") — which is what head, tail, grep and wc all
-- used — yields an extra empty match after every newline. That silently doubled
-- every line number grep reported and padded head/tail with blank lines. One
-- helper, so the fix can't be half-applied.
local function splitLines(source: string): { string }
	local lines: { string } = {}
	for line in (source .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	-- A trailing newline terminates the last line rather than starting an empty
	-- one; that is what `wc -l` counts, and what an editor shows.
	if #lines > 1 and lines[#lines] == "" and source:sub(-1) == "\n" then
		lines[#lines] = nil
	end
	return lines
end
Fs.splitLines = splitLines

-- =============================================================================
-- Searching a buffer
-- =============================================================================
export type GrepHit = { line: number, text: string, match: boolean }
export type GrepOpts = {
	usePattern: boolean?,
	ignoreCase: boolean?,
	invert: boolean?,
	before: number?,
	after: number?,
	limit: number?,
}

-- One buffer's worth of grep: which lines matched, plus the -A/-B/-C context
-- window around them, in line order and deduplicated where windows overlap.
--
-- Shared because grep runs over two different things — a script's Source and a
-- piped stream — and those two paths had already drifted once. A windowing loop
-- written twice is two places for an off-by-one to live, and an off-by-one here
-- is a context line reported under the wrong line number.
--
-- `limit` caps how many MATCHES get expanded, so a wide `-C 5` cannot smuggle
-- five times the intended output past the caller's cap. Returns the hits, the
-- number of matches expanded, and the number refused by the limit.
function Fs.grepLines(lines: { string }, needle: string, opts: GrepOpts?): ({ GrepHit }, number, number)
	local o = opts or {}
	local probe = o.ignoreCase and needle:lower() or needle
	local before, after = o.before or 0, o.after or 0
	local limit = o.limit or math.huge

	local matched: { [number]: boolean } = {}
	local wanted: { [number]: boolean } = {}
	local taken, skipped = 0, 0
	for index, line in ipairs(lines) do
		local subject = o.ignoreCase and line:lower() or line
		local hit
		if o.usePattern then
			hit = subject:find(probe) ~= nil
		else
			hit = subject:find(probe, 1, true) ~= nil
		end
		if o.invert then
			hit = not hit
		end
		if hit then
			matched[index] = true
			if taken >= limit then
				skipped += 1
			else
				taken += 1
				for i = math.max(1, index - before), math.min(#lines, index + after) do
					wanted[i] = true
				end
			end
		end
	end

	local hits: { GrepHit } = {}
	for index = 1, #lines do
		if wanted[index] then
			hits[#hits + 1] = { line = index, text = lines[index], match = matched[index] == true }
		end
	end
	return hits, taken, skipped
end

-- =============================================================================
-- Paths
-- =============================================================================
local function instancePath(inst: Instance): string
	if inst == game then
		return "/"
	end
	local parts = {}
	local current: Instance = inst
	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end
	if not current then
		return "/" .. inst.Name
	end
	return "/" .. table.concat(parts, "/")
end
Fs.instancePath = instancePath

-- Resolve `path` relative to `base`. Absolute paths ignore `base` entirely.
function Fs.resolve(base: Instance, path: string?): (Instance?, string?)
	if not path or path == "" or path == "." then
		return base, nil
	end

	local start: Instance
	local segments: { string }

	if path:sub(1, 1) == "/" then
		start = game
		segments = path:sub(2):split("/")
	else
		start = base
		segments = path:split("/")
	end

	local current: Instance = start
	for i, seg in ipairs(segments) do
		if seg == "" or seg == "." then
			-- no-op
		elseif seg == ".." then
			if current.Parent then
				current = current.Parent
			else
				return nil, "no parent (already at root)"
			end
		else
			-- `ls` prints scripts with a .luau suffix so Claude reads them as
			-- files, then feeds those names straight back to cat/cd/head/grep.
			-- Fixing this in resolve rather than in cat covers every command at
			-- once. Exact name wins: an instance may genuinely be named "foo.luau".
			--
			-- Every suffix a Roblox developer might write is accepted, not just
			-- `.luau` — `.lua`, and the `.server`/`.client` forms that name the
			-- script class. All of them resolve to the same instance, because in
			-- the DataModel the class is a property, not part of the name.
			local child = current:FindFirstChild(seg)
			if not child then
				local bare = Fs.stripScriptSuffix(seg)
				local stripped = bare and current:FindFirstChild(bare)
				if stripped and isScript(stripped) then
					child = stripped
				end
			end
			-- `workspace` is a real Luau global for game.Workspace, so a model
			-- writes it lowercase and is not wrong to — the engine accepts it
			-- everywhere else. Services generally: their names are fixed and
			-- unique, so a case-insensitive match at the root cannot be
			-- ambiguous. It stops at the root deliberately; two ordinary
			-- siblings really can differ only by case, and folding those
			-- together would resolve to whichever came first.
			if not child and current == game then
				local wanted = seg:lower()
				for _, service in ipairs(game:GetChildren()) do
					if service.Name:lower() == wanted then
						child = service
						break
					end
				end
			end
			-- Away from the root that fold no longer applies, but `workspace` is
			-- a Luau global: it means game.Workspace from any scope, so `ls
			-- workspace` from anywhere is the model writing Luau, not naming a
			-- child. Only the leading segment, and only when no real child has
			-- that name — a genuine sibling always wins. Workspace alone,
			-- because it is the one service that is also a global; the others
			-- need GetService in Luau too.
			if not child and i == 1 and seg:lower() == "workspace" then
				child = game:GetService("Workspace")
			end
			if not child then
				return nil, string.format("no child named %q in %s", seg, instancePath(current))
			end
			current = child
		end
	end

	return current, nil
end

-- Rojo's suffix convention, longest first so `.server.luau` is not mistaken for
-- `.luau` with a `.server` name. `.lua` is accepted alongside `.luau` because
-- half the ecosystem still writes it and a model will too.
local SCRIPT_SUFFIXES = {
	".server.luau", ".client.luau", ".server.lua", ".client.lua", ".luau", ".lua",
}

-- Strip a script suffix, or nil when there is none to strip.
function Fs.stripScriptSuffix(name: string): string?
	for _, suffix in ipairs(SCRIPT_SUFFIXES) do
		if #name > #suffix and name:sub(-#suffix) == suffix then
			return name:sub(1, -#suffix - 1)
		end
	end
	return nil
end

-- What `ls` shows for an instance. Scripts get a `.luau` so a model reads them
-- as files; everything else is its own name.
function Fs.displayName(inst: Instance): string
	return isScript(inst) and (inst.Name .. ".luau") or inst.Name
end

-- Split a path into parent and leaf; nil parent means "relative to the base".
function Fs.splitPath(path: string): (string?, string)
	local parent, leaf = path:match("^(.*)/([^/]+)$")
	if not leaf then
		return nil, path
	end
	return (parent == "" and "/" or parent), leaf
end

-- =============================================================================
-- Mutation
-- =============================================================================
-- Every mutation goes through withUndo. Without a ChangeHistoryService recording
-- the user's Ctrl+Z does nothing and a bad edit is unrecoverable — that is data
-- loss, not a rough edge, so it is not optional.
function Fs.withUndo<T>(label: string, action: () -> T): (T?, string?)
	-- TryBeginRecording returns nil if a recording is already open (another
	-- plugin, or a nested call). Proceed anyway: losing undo granularity beats
	-- refusing the edit, and Studio still has the outer recording.
	local recording = ChangeHistoryService:TryBeginRecording(label, label)
	local ok, result = pcall(action)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		return nil, tostring(result)
	end
	return result, nil
end

-- game and the services directly under it are not ours to move or delete.
function Fs.guardProtected(inst: Instance): string?
	if inst == game then
		return "refusing to modify the DataModel root"
	end
	if inst.Parent == game then
		return string.format("refusing to modify the service %q", inst.Name)
	end
	return nil
end

-- =============================================================================
-- Name matching
-- =============================================================================
-- Glob -> Lua pattern. Anchored, because a wildcard is the user saying where the
-- loose ends are; leaving it unanchored would make `Part*` and `*Part*` the same
-- query and the star meaningless.
local GLOB_MAGIC = "[%^%$%(%)%%%.%[%]%+%-%*%?]"
local function globToPattern(glob: string): string
	local pattern = glob:gsub(GLOB_MAGIC, function(c)
		if c == "*" then return ".*" end
		if c == "?" then return "." end
		return "%" .. c
	end)
	return "^" .. pattern .. "$"
end

-- Bare words stay substring matches, because `find Handler` should just work.
-- Anything containing a wildcard becomes an anchored glob. Everything is
-- lowercased, so -name and -iname are the same command here.
function Fs.nameMatcher(pattern: string): (string) -> boolean
	local needle = pattern:lower()
	if not pattern:find("[%*%?]") then
		return function(name)
			return name:lower():find(needle, 1, true) ~= nil
		end
	end
	local luaPattern = globToPattern(needle)
	return function(name)
		return name:lower():match(luaPattern) ~= nil
	end
end

-- =============================================================================
-- Values
-- =============================================================================
function Fs.formatValue(value: any): string
	local kind = typeof(value)
	if kind == "Instance" then
		return (value :: Instance):GetFullName()
	elseif kind == "table" then
		return "<table>"
	end
	return tostring(value)
end

-- Plain (non-pattern) occurrence count, for edit's uniqueness check.
function Fs.countOccurrences(haystack: string, needle: string): number
	if needle == "" then return 0 end
	local count, pos = 0, 1
	while true do
		local start, finish = haystack:find(needle, pos, true)
		if not start then break end
		count += 1
		pos = finish + 1
	end
	return count
end

return Fs
