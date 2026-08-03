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
	for _, seg in ipairs(segments) do
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
			local child = current:FindFirstChild(seg)
			if not child and seg:sub(-5) == ".luau" then
				local stripped = current:FindFirstChild(seg:sub(1, -6))
				if stripped and isScript(stripped) then
					child = stripped
				end
			end
			if not child then
				return nil, string.format("no child named %q in %s", seg, instancePath(current))
			end
			current = child
		end
	end

	return current, nil
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
