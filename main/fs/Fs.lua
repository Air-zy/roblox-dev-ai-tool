--!optimize 2
-- Fs.luau: the DataModel-as-filesystem primitives.
--
-- Everything here answers one of two questions: "which Instance does this path
-- mean?" and "how do I read or change it safely?". No commands, no shell, no
-- tool definitions, those sit on top of this. Split out of Terminal because
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
local CollectionService = game:GetService("CollectionService")

-- Studio-only. Fetched once rather than per call because the first thing that
-- uses it is getSource, which grep calls for every script in scope. Everything
-- built on it degrades to plain .Source if it is ever absent.
local ScriptEditorService: any = nil
do
	local ok, service = pcall(game.GetService, game, "ScriptEditorService")
	if ok then
		ScriptEditorService = service
	end
end

-- Studio-only, same treatment. Only `ActiveScript` is read from it here; the
-- shell reaches for GetUserId separately.
local StudioService: any = nil
do
	local ok, service = pcall(game.GetService, game, "StudioService")
	if ok then
		StudioService = service
	end
end

local Fs = {}

-- Scripts and source
-- True for anything with a readable .Source.
local function isScript(inst: Instance): boolean
	return inst:IsA("Script") or inst:IsA("LocalScript") or inst:IsA("ModuleScript")
end
Fs.isScript = isScript

-- The open ScriptDocument for a script, or nil when it is not open in the
-- editor. Exported because reads and writes both have to ask the same question,
-- and answering it two ways is how they would come to disagree.
local function openDocument(inst: Instance): any?
	if not ScriptEditorService then return nil end
	local ok, doc = pcall(function()
		return ScriptEditorService:FindScriptDocument(inst)
	end)
	return (ok and doc) or nil
end
Fs.openDocument = openDocument

-- Read a script's text. nil when the instance has none.
--
-- `.Source` is no longer the whole truth. Roblox decoupled the script editor
-- from that property, their words: "the source property will not always
-- reflect the script editor's content", so a script open in the editor with
-- unsaved edits has TWO texts, and .Source is the one the user is not looking
-- at. Reading it means `cat` shows the agent something that is not on screen
-- and `edit` matches old_string against text the user has already replaced.
--
-- So: the editor's buffer when a document is open, .Source when it is not.
--
-- ponytail: FindScriptDocument on every read, rather than a set of open
-- documents kept live by TextDocumentDidOpen/DidClose. The set would be O(1),
-- but it can DRIFT, one missed signal and reads fall silently back to stale
-- text, which is the exact failure this branch exists to remove, and a stateless
-- lookup cannot be wrong. Ceiling: one engine call per script per grep; the
-- cached set is the upgrade path if a place big enough to feel it turns up.
local function getSource(inst: Instance): string?
	if not isScript(inst) then return nil end
	-- Its own pcall, so a failure anywhere in the editor path falls back to
	-- .Source rather than returning nil, nil here reads as "not a script" and
	-- would drop the file out of a grep entirely.
	if ScriptEditorService then
		local ok, text = pcall(function()
			if openDocument(inst) then
				return ScriptEditorService:GetEditorSource(inst)
			end
			return nil
		end)
		if ok and type(text) == "string" then
			return text
		end
	end
	local ok, source = pcall(function() return (inst :: any).Source end)
	if ok and type(source) == "string" then
		return source
	end
	return nil
end
Fs.getSource = getSource

-- Fold CRLF to LF. UpdateSourceAsync has two reported bugs that both come down
-- to carriage returns: it does nothing when ONLY the line endings changed, and
-- with Live Scripting on it errors outright if the new text contains one.
-- Everything written here is Luau, where \r\n carries nothing the engine reads,
-- so normalising once at the write seam costs nothing and removes both.
local function normaliseNewlines(text: string): string
	return (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
end
Fs.normaliseNewlines = normaliseNewlines

-- The `.Source` SETTER refuses any string of 200,000 characters or more, and
-- refuses the WHOLE write rather than truncating. UpdateSourceAsync has no such
-- cap but needs an open document, so past this length the editor is not the
-- nicer path, it is the only one.
--
-- Measured rather than assumed: 210,013 characters through `.Source` is
-- "Provided string length (210013) is greater than or equal to max length
-- (200000)", and the same text through an opened document lands intact.
--
-- This is not hypothetical. fs/Shell is already past it, which meant the plugin
-- could no longer edit its own largest module: `edit` and `write` both ended at
-- that refusal, with the file left untouched.
local SOURCE_SETTER_LIMIT = 200000

-- Write a script's text, through the editor when the script is open. Returns an
-- error string, or nil on success.
--
-- Assigning .Source behind an open editor is what the decoupling announcement
-- warns about: the two buffers diverge and nothing documents which one wins.
-- Going through UpdateSourceAsync makes the EDITOR apply the change, so the
-- user's view updates in place, scroll and cursor survive, and the result stays
-- in their undo stack instead of being committed underneath them.
--
-- This YIELDS when a document is open, which is safe here and nowhere obvious:
-- tool dispatch runs from onComplete at message_stop, where the stream has
-- already delivered everything, and `catalog` has been yielding there for
-- seconds since it shipped.
function Fs.writeSource(inst: Instance, text: string): string?
	local content = normaliseNewlines(text)
	-- A byte-identical write is skipped rather than sent. UpdateSourceAsync is
	-- documented to fail when only the line endings changed, and after
	-- normalisation that is exactly what a no-op write looks like from here.
	if getSource(inst) == content then
		return nil
	end
	if openDocument(inst) then
		local ok, err = pcall(function()
			ScriptEditorService:UpdateSourceAsync(inst, function()
				return content
			end)
		end)
		return (not ok) and tostring(err) or nil
	end
	-- Not open, and too long for the setter: open it for the write and put it
	-- back. Only in this case — opening a document raises a tab in Studio, and
	-- doing that on every write would pull the user's focus once per edit.
	if #content >= SOURCE_SETTER_LIMIT and ScriptEditorService then
		local opened = pcall(function()
			ScriptEditorService:OpenScriptDocumentAsync(inst)
		end)
		if opened and openDocument(inst) then
			local ok, err = pcall(function()
				ScriptEditorService:UpdateSourceAsync(inst, function()
					return content
				end)
			end)
			-- Closed whether or not the write succeeded: the tab was opened by this
			-- function, so it belongs to it on both paths.
			pcall(function()
				local doc = openDocument(inst)
				if doc then
					doc:CloseAsync()
				end
			end)
			return (not ok) and tostring(err) or nil
		end
		-- Falls through on failure so the caller gets the engine's own refusal
		-- below, which names the limit, rather than a second-hand one from here.
	end
	local ok, err = pcall(function()
		(inst :: any).Source = content
	end)
	return (not ok) and tostring(err) or nil
end

-- Syntax check, through Luau's own grammar.
--
-- vendor/LuauParser is a port of Luau's Ast/src/Parser.cpp, so what comes back
-- here is what Studio itself would say, word for word, rather than an
-- approximation that drifts every time the language grows. Syntax ONLY: type
-- errors are analysis-time, luau-analyze is a separate binary, and no pure-Luau
-- checker in a plugin reaches them.
--
-- Required on first use rather than at load. It is 10 500 lines across three
-- modules and a session that only reads files never pays for compiling them.
local Parser: any = nil

-- How many errors are worth carrying back. The parser recovers and keeps going,
-- so one stray token can produce a screenful, and everything after the first is
-- usually cascade rather than a second real mistake.
local MAX_SYNTAX_ERRORS = 3

-- Returns nil when the source parses, or the errors as text.
function Fs.syntaxErrors(source: string): string?
	if not Parser then
		Parser = require(script.Parent.Parent:WaitForChild("vendor"):WaitForChild("LuauParser")) :: any
	end
	-- pcall'd, and a throw is swallowed rather than reported. This runs AFTER a
	-- write that already landed, so a checker that breaks must not turn a
	-- successful write into a failure: saying nothing is the correct way for it
	-- to fail.
	local called, parsed, result = pcall(Parser.parse, source)
	if not called or parsed or type(result) ~= "table" then
		return nil
	end
	local errors = result.errors
	if type(errors) ~= "table" or #errors == 0 then
		return nil
	end

	local out: { string } = {}
	for index, entry in ipairs(errors) do
		if index > MAX_SYNTAX_ERRORS then
			out[#out + 1] = string.format("… %d more", #errors - MAX_SYNTAX_ERRORS)
			break
		end
		-- Positions are VECTORS, not tables: .x is the line and .y the column,
		-- both 0-based. Reading them as .line/.column silently yields nil and
		-- every error reports "line nil".
		local at = entry.location and entry.location.begin
		out[#out + 1] = at
			and string.format("line %d:%d: %s", at.x + 1, at.y + 1, tostring(entry.message))
			or tostring(entry.message)
	end
	return table.concat(out, "\n")
end

-- Splitting with gmatch("[^\n]*"), which is what head, tail, grep and wc all
-- used: yields an extra empty match after every newline. That silently doubled
-- every line number grep reported and padded head/tail with blank lines. One
-- helper, so the fix can't be half-applied.
local function splitLines(source: string): { string }
	-- Empty text is ZERO lines, not one blank one. The scan below cannot say that
	-- on its own — it finds no newline and emits one empty line — and the
	-- trailing-newline guard is `#lines > 1`, so it never fired here. `wc -l` on
	-- an empty script answered 1, and once misses stopped flowing down pipes (see BASH_FIDELITY.md
	-- §3.1) it was `grep nothing . | wc -l` answering 1 as well, which is the
	-- exact wrong number that fix exists to remove.
	--
	-- A file holding only "\n" is still one line, an empty one, and still is:
	-- that path goes through the guard below untouched.
	if source == "" then
		return {}
	end
	-- Scanned with a plain `find`, not `(source .. "\n"):gmatch("(.-)\n")`. The
	-- concatenation copied the WHOLE file a second time on every read, and this
	-- is the hottest read there is: `grep -r /` runs it once per script in the
	-- place, on top of the copy `.Source` already handed back. The lazy `.-`
	-- pattern also scans a character at a time where a plain find does not.
	-- Same lines out, including the trailing-newline case the guard below fixes.
	local lines: { string } = {}
	local pos = 1
	while true do
		local newline = source:find("\n", pos, true)
		if not newline then
			lines[#lines + 1] = source:sub(pos)
			break
		end
		lines[#lines + 1] = source:sub(pos, newline - 1)
		pos = newline + 1
	end
	-- A trailing newline terminates the last line rather than starting an empty
	-- one; that is what `wc -l` counts, and what an editor shows.
	if #lines > 1 and lines[#lines] == "" and source:sub(-1) == "\n" then
		lines[#lines] = nil
	end
	return lines
end
Fs.splitLines = splitLines

-- Searching a buffer
export type GrepHit = { line: number, text: string, match: boolean }
export type GrepOpts = {
	invert: boolean?,
	only: boolean?,
	before: number?,
	after: number?,
	limit: number?,
}

-- Every place one of `programs` matches in `subject`, as {start, finish} pairs in
-- position order. nil when nothing matched, so a caller can tell "no match" from
-- "matched an empty string".
--
-- The programs arrive COMPILED. They used to be pattern strings re-interpreted by
-- string.find on every line of every script; compiling once per command and
-- matching per line is both faster and the only way a real engine can sit here at
-- all. Case-insensitivity lives inside the program, so nothing is lowercased on
-- the way past, captures have to come out of the original text.
--
-- `first` asks only "did anything match", and stops at the first hit. Every
-- caller but `-o` wants exactly that: grepLines reads `spans ~= nil` for the hit
-- test and never looks inside the list. Without it, a line holding forty
-- occurrences ran the engine forty times to answer yes — and grep's whole job is
-- to run this over every line of every script, so the wasted passes were
-- proportional to how MUCH a file matched, i.e. worst on exactly the searches
-- that matter. The returned list is still a list, so callers need no branch.
local function matchSpans(subject: string, programs: { any }, first: boolean?): { { number } }?
	local spans: { { number } }? = nil
	for _, program in ipairs(programs) do
		local from = 1
		while from <= #subject + 1 do
			local start, finish = program:find(subject, from)
			if not start then
				break
			end
			spans = spans or {}
			spans[#spans + 1] = { start, finish }
			if first then
				return spans
			end
			-- An empty match (`-E "x*"`) would otherwise never advance `from`.
			from = math.max(finish :: number, start) + 1
		end
	end
	if spans then
		table.sort(spans, function(a, b)
			return a[1] < b[1]
		end)
	end
	return spans
end

-- One buffer's worth of grep: which lines matched, plus the -A/-B/-C context
-- window around them, in line order and deduplicated where windows overlap.
--
-- Shared because grep runs over two different things, a script's Source and a
-- piped stream, and those two paths had already drifted once. A windowing loop
-- written twice is two places for an off-by-one to live, and an off-by-one here
-- is a context line reported under the wrong line number.
--
-- `programs` is a LIST because `-e` repeats, and a line matching ANY of them is
-- a hit.
--
-- `limit` caps how many MATCHES get expanded, so a wide `-C 5` cannot smuggle
-- five times the intended output past the caller's cap. Returns the hits, the
-- number of matches expanded, and the number refused by the limit.
function Fs.grepLines(lines: { string }, programs: { any }, opts: GrepOpts?): ({ GrepHit }, number, number)
	local o = opts or {}
	local before, after = o.before or 0, o.after or 0
	local limit = o.limit or math.huge

	local matched: { [number]: boolean } = {}
	local spansOf: { [number]: { { number } } } = {}
	local wanted: { [number]: boolean } = {}
	local taken, skipped = 0, 0
	for index, line in ipairs(lines) do
		-- Only -o reads the span list; everything else needs the yes/no, so stop
		-- at the first match rather than enumerating every one to discard them.
		local spans = matchSpans(line, programs, not o.only)
		local hit = spans ~= nil
		if o.invert then
			hit = not hit
		end
		if hit then
			matched[index] = true
			if spans then
				spansOf[index] = spans
			end
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
			local isMatch = matched[index] == true
			local spans = spansOf[index]
			if o.only and isMatch and spans then
				-- -o emits the matched text rather than the line, once per match.
				-- A context line has nothing to extract and passes through whole.
				for _, span in ipairs(spans) do
					hits[#hits + 1] = {
						line = index, text = lines[index]:sub(span[1], span[2]), match = true,
					}
				end
			else
				hits[#hits + 1] = { line = index, text = lines[index], match = isMatch }
			end
		end
	end
	return hits, taken, skipped
end

-- Paths
local function instancePath(inst: Instance): string
	if inst == game then
		return "/"
	end
	-- Appended and reversed, not `table.insert(parts, 1, ...)`: inserting at the
	-- front shifts every element already there, so building a path of depth d
	-- costs O(d²). Invisible at depth 10 and not free at depth 100, which is
	-- where it matters, since `find -path`/`-regex` call this once per node.
	local parts = {}
	local current: Instance = inst
	while current and current ~= game do
		parts[#parts + 1] = current.Name
		current = current.Parent
	end
	if not current then
		return "/" .. inst.Name
	end
	for i = 1, #parts // 2 do
		parts[i], parts[#parts + 1 - i] = parts[#parts + 1 - i], parts[i]
	end
	return "/" .. table.concat(parts, "/")
end
Fs.instancePath = instancePath

-- One child by name: the exact name, or a script addressed by the displayed
-- `.luau` form that `ls` prints. Shared with the slash fallback in resolve so
-- both spellings work there too — two copies would be two lists to keep in
-- sync, and the slash path would be the one that silently disagreed.
-- A DataModel lets siblings share a name; a filesystem does not, and every path
-- in this shell is written as though it could not. `FindFirstChild` returned
-- whichever duplicate came first, so a path was not a handle to one instance —
-- it was a handle to whichever one the engine listed first, and two different
-- commands could disagree about which.
--
-- That is data loss, not an inconvenience. With a ModuleScript and a Folder both
-- literally named `target.luau`:
--     find . -type d -name target.luau     matched the FOLDER
--     find . -type d -name target.luau -exec rm -r {} \;
--                                          destroyed the MODULESCRIPT
-- and the transcript looked entirely correct. `rm -r target.luau` typed by hand
-- did the same thing, so this was never an `-exec` defect — every command that
-- takes a path had it, which is why the guard belongs here and not in any of
-- them. cp/mv already refuse an ambiguous destination; this is the same rule at
-- the other end.
--
-- ponytail: GetChildren allocates a table of N to check uniqueness, where
-- FindFirstChild allocated nothing. Ceiling: one such table per resolved path
-- segment, so a path INTO a 10k-child container costs a 10k-entry table per
-- command. Only paid once a lookup has already succeeded, and `ls -R` no longer
-- re-resolves at all. Upgrade path is an engine-side unique-name lookup, which
-- does not exist today.
local function findChild(parent: Instance, name: string): (Instance?, string?)
	if not parent:FindFirstChild(name) then
		-- Every suffix a Roblox developer might write is accepted, not just
		-- `.luau`: `.lua`, and the `.server`/`.client` forms that name the script
		-- class. All of them resolve to the same instance, because in the
		-- DataModel the class is a property, not part of the name.
		--
		-- Only reached when no child carries the written name exactly, so an
		-- instance literally called `foo.luau` still wins over a script `foo`.
		local bare = Fs.stripScriptSuffix(name)
		if not bare then
			return nil
		end
		local script, scripts = nil, 0
		for _, child in ipairs(parent:GetChildren()) do
			if child.Name == bare and isScript(child) then
				scripts += 1
				script = script or child
			end
		end
		if scripts > 1 then
			return script, string.format("%q names %d scripts in %s",
				name, scripts, instancePath(parent), bare)
		end
		return script
	end
	local exact, count = nil, 0
	-- Which duplicate a READ gets has to be the same answer twice. GetChildren
	-- has no defined order -- this file sorts for `diff -r` and Tools sorts its
	-- modules for exactly that reason -- so "the first match" was really "whichever
	-- the engine happened to hand back", and `cat twin.luau` could return a
	-- different instance between sessions.
	--
	-- A written script suffix says which kind was meant, so a script wins over a
	-- Folder of the same name. That is the rule the suffix branch above already
	-- follows; this makes the exact-name branch agree with it. Mutating callers
	-- still refuse on the note below, so this only decides what a read sees.
	local wantsScript = Fs.stripScriptSuffix(name) ~= nil
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then
			count += 1
			if exact == nil
				or (wantsScript and isScript(child) and not isScript(exact)) then
				exact = child
			end
		end
	end
	if count > 1 then
		return exact, string.format("%q names %d siblings in %s",
			name, count, instancePath(parent))
	end
	return exact
end

-- Resolve `path` relative to `base`. Absolute paths ignore `base` entirely.
-- Third return: the path resolved, but a component of it named more than one
-- instance and this is the first such component. A DataModel allows duplicate
-- sibling names where a filesystem does not, so a path is not always a unique
-- handle. Reading resolves to ONE of them and never refuses; MUTATING callers
-- refuse on this note, because that is where picking the wrong one destroys
-- something.
--
-- Which one a read gets is decided in findChild, not left to GetChildren: a
-- written script suffix picks the script. It used to be whichever the engine
-- returned first, so the same `cat` could answer differently between sessions —
-- and the twin test that shipped alongside this split has always asserted the
-- script wins, which only held because insertion order made it so.
--
-- Refusing on every lookup instead made ~25% of a stock place unreachable for
-- reading, which bought nothing -- a read cannot corrupt.
function Fs.resolve(base: Instance, path: string?): (Instance?, string?, string?)
	if not path or path == "" or path == "." then
		return base, nil
	end
	local duplicate: string? = nil

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
	-- A while loop rather than ipairs: a Name that contains "/" spans several
	-- segments, and the fallback at the bottom has to skip past the ones it
	-- consumed.
	local i = 1
	while i <= #segments do
		local seg = segments[i]
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
			local child, ambiguous = findChild(current, seg)
			duplicate = duplicate or ambiguous
			-- `workspace` is a real Luau global for game.Workspace, so a model
			-- writes it lowercase and is not wrong to, the engine accepts it
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
			-- that name, a genuine sibling always wins. Workspace alone,
			-- because it is the one service that is also a global; the others
			-- need GetService in Luau too.
			if not child and i == 1 and seg:lower() == "workspace" then
				child = game:GetService("Workspace")
			end
			-- A Name is allowed to contain "/", the separator itself, and mesh
			-- imports do it by default: a MeshPart arrives named
			-- "Meshes/Anime_Girl". instancePath emits that raw, so the path it
			-- produces splits back apart in the wrong place, and `ls -R` — which
			-- walks by re-resolving the paths it prints — reported the LEADING
			-- fragment missing, `no child named "Meshes"`, while the instance sat
			-- right there in the listing it had just printed. Worse, that error
			-- aborted the whole walk, so one imported mesh anywhere in a subtree
			-- returned nothing but the error. Every other lookup is tried first,
			-- so a real child always wins over this.
			--
			-- ponytail: longest match first, no backtracking. Ceiling: a name
			-- that is also a real path ("a/b" beside a folder "a" holding "b")
			-- picks the deeper one. Full backtracking is the upgrade path if a
			-- place ever manages to be that ambiguous.
			if not child then
				for j = #segments, i + 1, -1 do
					local joined, joinedAmbiguous = findChild(current, table.concat(segments, "/", i, j))
					if joined then
						duplicate = duplicate or joinedAmbiguous
						child = joined
						i = j
						break
					end
				end
			end
			if not child then
				return nil, string.format("no child named %q in %s", seg, instancePath(current))
			end
			current = child
		end
		i += 1
	end

	return current, nil, duplicate
end

-- Rojo's suffix convention, longest first so `.server.luau` is not mistaken for
-- `.luau` with a `.server` name. `.lua` is accepted alongside `.luau` because
-- half the ecosystem still writes it and a model will too.
--
-- ONE table, read two ways: resolving a path only wants the suffix off, and
-- creating a leaf also wants the class it names. Two tables would be two lists
-- to keep in sync, and the first one to gain a suffix would be the one that
-- silently disagreed.
local SCRIPT_SUFFIXES = {
	{ ".server.luau", "Script" },
	{ ".client.luau", "LocalScript" },
	{ ".server.lua", "Script" },
	{ ".client.lua", "LocalScript" },
	{ ".luau" },
	{ ".lua" },
}

local function stripSuffix(name: string): (string?, string?)
	for _, entry in ipairs(SCRIPT_SUFFIXES) do
		local suffix = entry[1]
		if #name > #suffix and name:sub(-#suffix) == suffix then
			return name:sub(1, -#suffix - 1), entry[2]
		end
	end
	return nil, nil
end

-- Strip a script suffix, or nil when there is none to strip.
function Fs.stripScriptSuffix(name: string): string?
	return (stripSuffix(name))
end

-- Which class a NEW leaf should be, and the name to give it once the suffix is
-- off. No suffix, or a bare `.luau`, means ModuleScript, the safe default,
-- since it does nothing until something requires it.
function Fs.classFor(leaf: string): (string, string)
	local bare, class = stripSuffix(leaf)
	return class or "ModuleScript", bare or leaf
end

-- Does this name already read as a filename?
--
-- A ModuleScript is the only thing here with somewhere to put text, so a file
-- that is not Luau — a README, a .json, a .toml — arrives as one with its own
-- extension kept in the Name. `Main` is a script and wants `.luau` added;
-- `README.md` is a file and already has its suffix.
--
-- The test is safe because classFor STRIPS script suffixes on the way in:
-- nothing here is ever named `Main.luau`, so a dot that survived into a Name
-- came from a file that was not a script in the first place.
function Fs.carriesExtension(name: string): boolean
	return name:find("%.[^./]+$") ~= nil and not name:match("%.luau?$")
end

-- What `ls` shows for an instance. Scripts get a `.luau` so a model reads them
-- as files; everything else is its own name, and so is a script that arrived
-- carrying one — `README.md.luau` would be a name nothing can open.
function Fs.displayName(inst: Instance): string
	if isScript(inst) and not Fs.carriesExtension(inst.Name) and not inst.Name:match("%.luau?$") then
		return inst.Name .. ".luau"
	end
	return inst.Name
end

-- Does a name filter accept this instance? Every spelling a model might write:
-- the real name, and for scripts BOTH suffixes. `ls` only ever prints `.luau`,
-- but `.lua` is what half the ecosystem writes and resolve already accepts it,
-- so `--include=*.lua` returning nothing was the harness disagreeing with
-- itself: `cat Main.lua` worked, `grep --include=*.lua` found no such file.
function Fs.matchesName(inst: Instance, matches: (string) -> boolean): boolean
	return matches(inst.Name)
		or (isScript(inst) and (matches(inst.Name .. ".luau") or matches(inst.Name .. ".lua")))
end

-- Split a path into parent and leaf; nil parent means "relative to the base".
function Fs.splitPath(path: string): (string?, string)
	local parent, leaf = path:match("^(.*)/([^/]+)$")
	if not leaf then
		return nil, path
	end
	return (parent == "" and "/" or parent), leaf
end

-- Observed modification times
-- Instances carry no timestamp. Not Created, not Modified, nothing in the API
-- dump and nothing behind a security level a plugin can reach, so `ls -t`,
-- `find -newer` and `touch -d` have no stored value to read, and the honest
-- alternatives were to refuse them or to observe the times ourselves.
--
-- Two session-wide signals, neither needing a per-instance listener:
--   game.DescendantAdded            anything created, cloned or REPARENTED
--                                   (a move fires DescendantRemoving then
--                                   DescendantAdded, so mv lands here too)
--   TextDocumentDidChange           every edit the user makes in the Script
--                                   Editor, one connection for the session
-- plus explicit touches from Terminal:write and :multiedit, which change .Source
-- without moving anything and so appear in neither signal.
--
-- This is therefore a PLUGIN-OBSERVED mtime, and the distinction is the whole
-- point: nothing that happened before we loaded is in here, and neither is a
-- property changed through the Properties panel. Those read back nil, render as
-- "-", and sort last. Callers must SHOW that rather than imply a time they do
-- not have, an unlabelled partial answer is worse than none, because there is
-- no way to tell it from a complete one.
--
-- ponytail: weak-keyed, so a Destroy()d instance drops out with no bookkeeping.
-- Ceiling: session-local, and blind to the Properties panel. Upgrade path is a
-- Changed connection per instance, thousands of connections to fill in one
-- column of `ls`, not worth it until something else needs live change tracking.
local mtimes: { [Instance]: number } = (setmetatable({}, { __mode = "k" }) :: any)

function Fs.touch(inst: Instance, when: number?)
	mtimes[inst] = when or os.time()
end

function Fs.mtime(inst: Instance): number?
	return mtimes[inst]
end

-- Wire the session-wide sources. Called once from main; a second call is a
-- no-op rather than a second set of connections.
--
-- HELD, not fired and forgotten. Both signals live on objects that outlive the
-- plugin — `game` and ScriptEditorService — so a connection to either survives
-- the plugin being unloaded and goes on running against a dead closure. Studio
-- unloads and reloads a plugin every time its file is rewritten, which for this
-- one is every rebuild, so the copies accumulate for as long as Studio is open
-- and only a restart clears them. See Fs.unload.
local watching = false
local watchConnections: { RBXScriptConnection } = {}
function Fs.watch()
	if watching then return end
	watching = true
	watchConnections[#watchConnections + 1] = game.DescendantAdded:Connect(function(inst)
		mtimes[inst] = os.time()
	end)
	-- Guarded because a missing event must not take the plugin down over a signal
	-- that only fills in one column of `ls`.
	if ScriptEditorService then
		pcall(function()
			watchConnections[#watchConnections + 1] =
				ScriptEditorService.TextDocumentDidChange:Connect(function(document: any)
					local target = document and document:GetScript()
					if target then
						mtimes[target] = os.time()
					end
				end)
		end)
	end
end

-- Drop the session-wide connections. Called from plugin.Unloading.
--
-- `watching` is cleared too, so a plugin that is unloaded and loaded again in
-- the same Studio session re-wires rather than coming back deaf.
function Fs.unload()
	for _, connection in ipairs(watchConnections) do
		connection:Disconnect()
	end
	table.clear(watchConnections)
	watching = false
end

-- The script the user is actually editing, or nil.
--
-- `ScriptDocument` cannot answer this — it has no "is this the front tab"
-- member, which is what led to the claim in Agent.editorContext that there is no
-- focus API at all. There is: StudioService.ActiveScript, a read-only Instance,
-- and it is the difference between listing six open files and naming the one.
--
-- nil is a real answer, not just a failure: with a 3D viewport in front and no
-- script tab open, nothing is being edited.
function Fs.activeScript(): Instance?
	if not StudioService then
		return nil
	end
	local ok, active = pcall(function()
		return StudioService.ActiveScript
	end)
	if ok and typeof(active) == "Instance" then
		return active
	end
	return nil
end

-- Every script currently open in the editor, as { instance, document, active }
-- triples, the ACTIVE one first. Command Bar documents are skipped: they have no
-- script behind them and are not a file anyone is editing.
--
-- Ordered here rather than by the caller because there is only one right order
-- and every caller wants it: GetScriptDocuments returns them in an order nobody
-- has documented, so "the first one" meant nothing before.
function Fs.openDocuments(): { { inst: Instance, doc: any, active: boolean } }
	local out: { { inst: Instance, doc: any, active: boolean } } = {}
	if not ScriptEditorService then
		return out
	end
	local active = Fs.activeScript()
	pcall(function()
		for _, doc in ipairs(ScriptEditorService:GetScriptDocuments()) do
			if not doc:IsCommandBar() then
				local inst = doc:GetScript()
				if inst then
					local entry = { inst = inst, doc = doc, active = inst == active }
					if entry.active then
						-- Front of the list, so a caller that can only afford a few
						-- entries keeps the one that matters.
						table.insert(out, 1, entry)
					else
						out[#out + 1] = entry
					end
				end
			end
		end
	end)
	return out
end

-- Mode bits
-- There is no permission system here, but there are three booleans that mean
-- what three of the mode bits mean, and they are the three `ls -l`, `chmod` and
-- `find -perm` are actually reached for:
--
--   x   BaseScript.Disabled, inverted   will this run?
--   a   Instance.Archivable             will Clone() and the place save take it?
--   l   BasePart.Locked                 is it pinned against selection in Studio?
--
-- Not every class has every bit. A ModuleScript has no Disabled, it runs when
-- something requires it, so there is nothing to disable, and only a BasePart
-- has Locked. Those slots read "-", and setMode REFUSES them rather than
-- accepting the request and changing nothing.
--
-- Deliberately no octal form: 755 encodes user/group/other, and with no owner
-- here the three digits have nothing to mean. A mapping would have to be
-- invented, and an invented one is worse than none.
local MODE_LETTERS = "xal"

-- The bit a letter names, or nil when this class has no such bit. Written out
-- rather than as `cond and value or nil`, which collapses to nil for a bit that
-- exists and is false, the exact case that has to be told from "no such bit".
local function modeBit(inst: Instance, letter: string): boolean?
	if letter == "x" then
		if not inst:IsA("BaseScript") then return nil end
		return not (inst :: any).Disabled
	elseif letter == "a" then
		return inst.Archivable
	elseif letter == "l" then
		if not inst:IsA("BasePart") then return nil end
		return (inst :: any).Locked
	end
	return nil
end
Fs.modeBit = modeBit

function Fs.modeString(inst: Instance): string
	local out: { string } = {}
	for letter in MODE_LETTERS:gmatch(".") do
		out[#out + 1] = modeBit(inst, letter) and letter or "-"
	end
	return table.concat(out)
end

-- One clause of chmod's symbolic form. Returns an error string when the class
-- has no such bit, so the caller reports a refusal rather than a success that
-- changed nothing.
function Fs.setMode(inst: Instance, letter: string, on: boolean): string?
	if modeBit(inst, letter) == nil then
		if letter == "x" then
			return string.format("%s has no execute bit — only a Script or LocalScript " ..
				"can be disabled, and a ModuleScript runs when something requires it",
				inst.ClassName)
		end
		if letter == "l" then
			return string.format("%s has no lock bit — Locked is a BasePart property",
				inst.ClassName)
		end
		return string.format("%s has no %q bit — chmod here takes x (Disabled), " ..
			"a (Archivable) and l (Locked)", inst.ClassName, letter)
	end
	if letter == "x" then
		-- Disabled rather than Enabled: Disabled is the replicated, serialised
		-- one, so it is what actually persists into the place file. Enabled is
		-- its non-replicated mirror.
		(inst :: any).Disabled = not on
	elseif letter == "a" then
		inst.Archivable = on
	elseif letter == "l" then
		(inst :: any).Locked = on
	end
	return nil
end

-- Keeping Studio responsive during a walk
-- Luau is single-threaded and this plugin shares that thread with the editor,
-- so a walk over a large place is not a slow command, it is a frozen window: no
-- rendering, no input, and eventually Studio's own not-responding dialog on top
-- of it. `find`, `grep`, `tree` and `ls -R` all walk without a natural stopping
-- point, and a place with a few hundred thousand instances is an ordinary size
-- for a game someone is asking an agent about.
--
-- Yielding from tool dispatch is safe, and not by accident: dispatch runs from
-- onComplete at message_stop, where the stream has already delivered
-- everything. Fs.writeSource and `catalog` have both been yielding there since
-- they shipped.
--
-- Time, not a counter. A counter added a fixed cost to every walk whether or
-- not it was slow — `ls -R` over twenty instances would still stop to wait —
-- and it cannot know how expensive one step was, which for grep is a whole
-- script read through the editor. This yields only once the thread has actually
-- been held for a frame, so a small place never waits at all and a huge one
-- gives a frame back every frame.
local BREATH = 1 / 60

-- Returns a function to call once per node visited. One closure per walk, and
-- the deadline lives in it, so nested walks cannot reset each other's.
function Fs.breather(): () -> ()
	local deadline = os.clock() + BREATH
	return function()
		if os.clock() < deadline then
			return
		end
		task.wait()
		deadline = os.clock() + BREATH
	end
end

-- Size and identity
-- A script's size is its source in bytes, a real byte count, and the one `wc
-- -c` already reports. Nothing else here has bytes to count, so its size is its
-- descendant count, which is the measure `du` and `ls -l` were already using.
-- Kept identical so those three commands cannot disagree about one instance.
--
-- Returns whether the number is bytes, because -h may only scale the byte form:
-- "1.2K descendants" is a unit that does not exist.
function Fs.size(inst: Instance): (number, boolean)
	local source = getSource(inst)
	if source then
		return #source, true
	end
	return #inst:GetDescendants(), false
end

local UNITS = { "K", "M", "G" }

function Fs.humanSize(bytes: number): string
	if bytes < 1024 then
		return tostring(bytes)
	end
	local n = bytes
	local unit = UNITS[#UNITS]
	for _, suffix in ipairs(UNITS) do
		n /= 1024
		if n < 1024 then
			unit = suffix
			break
		end
	end
	-- coreutils keeps one decimal below 10 and drops it above: 1.2K, then 34K.
	return string.format(n < 10 and "%.1f%s" or "%.0f%s", n, unit)
end

-- The closest thing here to an inode. GetDebugId is PluginSecurity, which is
-- the level this runs at. It identifies an instance within ONE Studio session
-- and is not stable across restarts, which is exactly the job `ls -i` is used
-- for, telling two identically-named instances apart.
function Fs.debugId(inst: Instance): string
	local ok, id = pcall(function()
		return inst:GetDebugId()
	end)
	return (ok and type(id) == "string") and id or "?"
end

-- Tags and attributes: the two pieces of instance metadata with no property to
-- read them off, and so the two `stat` could not see at all. A tag is the
-- closest thing here to a file's extended attribute set, an attribute the
-- closest to a key/value one.
--
-- Sorted, because GetTags and GetAttributes both answer in an order nobody
-- documents, and stat run twice on the same instance should not disagree with
-- itself about the order it lists them in.
function Fs.tags(inst: Instance): { string }
	local tags = CollectionService:GetTags(inst)
	table.sort(tags)
	return tags
end

-- Kept apart from Fs.tags because this is the one on a hot path: `find -tag`
-- asks it per node, and GetTags would allocate a table for every instance in
-- the place to answer a question about one string.
--
-- ponytail: a walk, where CollectionService:GetTagged is an INDEX and would
-- make `find / -tag X` O(matches) instead of O(place). Seeding find's results
-- from the index needs the depth bounds and the tree ordering rebuilt off it,
-- and it only holds while -tag is the whole expression. Upgrade path if a place
-- turns up where the walk is felt.
function Fs.hasTag(inst: Instance, tag: string): boolean
	return CollectionService:HasTag(inst, tag)
end

-- Mutation
-- Every mutation goes through withUndo. Without a ChangeHistoryService recording
-- the user's Ctrl+Z does nothing and a bad edit is unrecoverable, that is data
-- loss, not a rough edge, so it is not optional.
function Fs.withUndo<T>(label: string, action: () -> T): (T?, string?)
	-- One recording per PLUGIN, not per Studio: another plugin's recording does
	-- not block ours, so a nil here means a nested call of our own. Proceed
	-- anyway -- losing undo granularity beats refusing the edit, and the outer
	-- recording still captures the change.
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
		return "refusing to modify /"
	end
	if inst.Parent == game then
		return string.format("refusing to modify the service %q", inst.Name)
	end
	return nil
end

-- Name matching
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
-- Anything containing a wildcard becomes an anchored glob.
--
-- `exact` turns off the substring fallback, so a wildcard-free pattern has to be
-- the whole name. That is what `find -name` means everywhere else: GNU matches
-- the name against a GLOB, and a glob with no wildcard in it matches exactly one
-- string. Loose matching is right for the bare `find Handler` shorthand, which
-- is this harness's own invention and is meant to be forgiving, and wrong for
-- `-name`, where it silently reports MORE than was asked for — `-name Main` also
-- returning `mainframe` and `Remainder` is a search whose extra hits look
-- exactly like real ones.
--
-- `caseSensitive` is the only thing that has ever separated `-name` from
-- `-iname`. Without it they were the same function and one of the two was a lie
-- whichever way you read it.
export type NameOpts = { exact: boolean?, caseSensitive: boolean? }

function Fs.nameMatcher(pattern: string, opts: NameOpts?): (string) -> boolean
	local o = opts or {}
	local fold = not o.caseSensitive
	local needle = if fold then pattern:lower() else pattern
	local function prepare(name: string): string
		return if fold then name:lower() else name
	end
	if not pattern:find("[%*%?]") then
		if o.exact then
			return function(name)
				return prepare(name) == needle
			end
		end
		return function(name)
			return prepare(name):find(needle, 1, true) ~= nil
		end
	end
	-- Globs are their own syntax, not regex, and they compile to a Lua pattern
	-- purely as an implementation detail, nothing about it reaches the caller.
	local compiled = globToPattern(needle)
	return function(name)
		return prepare(name):match(compiled) ~= nil
	end
end

-- Values
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
