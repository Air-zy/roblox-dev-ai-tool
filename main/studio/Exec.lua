--!strict
--!optimize 2
-- Executing Luau from the plugin. Reached only through the `run` tool, no
-- shell command touches it, which is why it is not in Terminal.
--
-- Takes a terminal as its first argument for path resolution and nothing else.
local Fs = require(script.Parent.Parent:WaitForChild("fs"):WaitForChild("Fs"))
local isScript     = Fs.isScript
local getSource    = Fs.getSource
local instancePath = Fs.instancePath
local formatValue  = Fs.formatValue

local Exec = {}

-- run: execute Luau in Studio
-- `loadstring` is unavailable to plugins, and shipping one gets a plugin
-- moderated, so execution goes through the supported route: build a
-- ModuleScript, parent it, require it.
--
-- A NEW ModuleScript every call is mandatory, not tidiness. Edit-mode require
-- caches per instance, and that cache does not clear when the source changes
-- reusing one module would silently return the first run's result forever.
local ServerStorage = game:GetService("ServerStorage")
-- The Output window, as a signal. Used to catch what the chunk's own shadowed
-- print/warn cannot see, see the listener in Exec.run.
local LogService = game:GetService("LogService")

-- Arbitrary code at plugin permission level can do anything the plugin can:
-- delete the place, fire HTTP requests. Off unless the user opts in.
local runGuard: (() -> boolean)? = nil
function Exec.setRunGuard(guard: () -> boolean)
	runGuard = guard
end

-- print/warn are shadowed as locals so the chunk's own calls land in __out
-- instead of the Studio output window, where they'd be lost to the agent.
-- Keep this table in sync with nothing else, its LENGTH is the line offset
-- used to translate error line numbers back to the user's code.
--
-- EVERY ENTRY MUST BE EXACTLY ONE PHYSICAL LINE. PROLOGUE_LINES below is #PROLOGUE,
-- and a two-line entry shifts every error line number this tool ever reports
-- silently, and in the direction that makes the agent edit the wrong line. That
-- is why __fmt and reload are single long lines rather than formatted blocks.
--
-- `require` is shadowed too, but only to RECORD. It delegates straight to the
-- real one, so behaviour is unchanged; the list comes back in the result so the
-- caller can notice a run that used a stale cache entry. It observes, it does
-- not intervene, see the note on reload below for why not.
--
-- ponytail: shadowing is a LOCAL, so all of this covers the chunk's own calls
-- and nothing else. A module's own `require` calls use the real global and are
-- invisible here, which is exactly why `require` is not made to auto-reload:
-- it would fix the top level and leave nested staleness untouched, which looks
-- like freshness and is not. Ceiling: an Actor gets its own module cache and is
-- the only thing that makes nested requires genuinely fresh.
local PROLOGUE = {
	'local __out = {}',
	'local function __fmt(...) local n = select("#", ...) local p = table.create(n) for i = 1, n do p[i] = tostring((select(i, ...))) end return table.concat(p, " ") end',
	'local print = function(...) table.insert(__out, __fmt(...)) end',
	'local warn = function(...) table.insert(__out, "[warn] " .. __fmt(...)) end',
	'local __rawrequire = require',
	'local __required, __reloaded = {}, {}',
	'local require = function(m) if typeof(m) == "Instance" then table.insert(__required, m) end return __rawrequire(m) end',
	-- reload: clone, require the clone, destroy it. The cache is keyed per
	-- Instance, so a clone is a fresh key, the only way to re-run a module in
	-- edit mode. Memoised per run, so two reloads of one module in a single
	-- chunk return the same table and singletons still behave; freshness is per
	-- run, which is what a real test runner gets from a new process.
	'local function reload(m) if typeof(m) ~= "Instance" then error("reload takes a ModuleScript instance, as reload(game.ServerStorage.Tests.Foo)", 2) end if __reloaded[m] ~= nil then return __reloaded[m] end if not m.Archivable then error("cannot reload " .. m:GetFullName() .. ": Archivable is false, so it cannot be cloned", 2) end local c = m:Clone() c.Parent = m.Parent local ok, r = pcall(__rawrequire, c) c:Destroy() if not ok then error(r, 2) end __reloaded[m] = r return r end',
	'local __clock = os.clock()',
	-- table.pack rather than `local __ok, __ret =`: a chunk ending in
	-- `return a, b` used to lose everything past the first value, silently, and
	-- a function returning `value, err` is the single most common shape in Luau
	--, so the one return worth seeing was the one that vanished. __res[1] is
	-- pcall's ok; 2..n are the returns, or the error on the failure path.
	'local __res = table.pack(pcall(function()',
}
local EPILOGUE = {
	'end))',
	'return { ok = __res[1], ret = table.move(__res, 2, __res.n, 1, { n = __res.n - 1 }), out = __out, required = __required, elapsed = os.clock() - __clock }',
}
local PROLOGUE_LINES = #PROLOGUE
local MAX_OUTPUT_LINES = 40

-- When each module was FIRST required this session, which is when its cache
-- entry was populated, and the only timestamp worth comparing an edit against.
-- Deliberately never refreshed on a later require: refreshing it would move the
-- mark past every edit and the staleness check below could never fire.
--
-- Weak-keyed, so a Destroy()d module drops out with no bookkeeping, the same
-- shape as the mtime journal in Fs.
local requiredAt: { [Instance]: number } = (setmetatable({}, { __mode = "k" }) :: any)

-- Shallow, bounded rendering: a returned table is usually the interesting part,
-- but a deep dump of the DataModel would flood the context.
local MAX_VALUE_CHARS = 500

local function describe(value: any, depth: number?): string
	if typeof(value) ~= "table" then
		local s = formatValue(value)
		if #s > MAX_VALUE_CHARS then
			return s:sub(1, MAX_VALUE_CHARS)
				.. string.format(" ... [%d more]", #s - MAX_VALUE_CHARS)
		end
		return s
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

-- `code` is one-shot; `path` reads the code out of a script instead, so a probe
-- can be written once and re-run after an edit rather than resent whole. Exactly
-- Runs a string. INTERNAL: the tool only reaches Exec.run below, which reads the
-- source out of a file first. Kept separate so the self-tests can drive the
-- executor without writing a fixture to the DataModel for every case.
local function runSource(self: any, code: string?): (string?, string?)
	if not code or code:match("^%s*$") then
		return nil, "nothing to run"
	end
	if not runGuard or not runGuard() then
		return nil, "code execution is disabled — enable it in Settings > Run code"
	end

	local source = table.concat(PROLOGUE, "\n") .. "\n" .. code .. "\n" .. table.concat(EPILOGUE, "\n")

	local module = Instance.new("ModuleScript")
	module.Name = "ClaudeRun_" .. tostring(os.clock()):gsub("%.", "")
	module.Source = source
	module.Parent = ServerStorage

	-- Everything the chunk itself prints is captured by PROLOGUE, which shadows
	-- print and warn as locals. That shadowing stops at the chunk's own scope
	-- a REQUIRED module has its own, so its print goes to the Output window, and
	-- an error inside a task the chunk spawns escapes the pcall below entirely.
	-- Both used to vanish, and `run` reported success on top of them.
	--
	-- Listening to LogService for the length of the call catches exactly those.
	-- The two channels cannot overlap: anything reaching LogService here is by
	-- construction something the chunk could not capture, because what it can
	-- capture never gets there.
	local escaped: { string } = {}
	local listener: RBXScriptConnection? = nil
	pcall(function()
		listener = LogService.MessageOut:Connect(function(message: string, messageType: EnumItem)
			-- Read by name rather than compared against Enum.MessageType members,
			-- so a misremembered member name cannot silently mis-tag every line.
			local kind = messageType and messageType.Name or ""
			local prefix = ""
			if kind == "MessageError" then
				prefix = "[error] "
			elseif kind == "MessageWarning" then
				prefix = "[warn] "
			end
			escaped[#escaped + 1] = prefix .. tostring(message)
		end)
	end)

	-- ponytail: no timeout. Luau cannot preempt a running chunk, so
	-- `while true do end` freezes Studio until its own script-exhaustion
	-- timeout fires. The tool description tells Claude to bound its loops;
	-- there is no in-process fix short of running the code in a separate
	-- Actor with a watchdog, which is the upgrade path if this bites.
	local result
	local ranOk, requireErr = pcall(function()
		result = require(module)
	end)

	-- One frame before disconnecting, and it is not politeness, without it this
	-- whole listener captures NOTHING in the common case.
	--
	-- Template places are created with Workspace.SignalBehavior = Deferred, where
	-- a handler does not run when the event fires: it is queued and resumed at
	-- the next resumption point. Disconnect is documented to "drop all pending
	-- event handler invocations". A chunk that never yields therefore reaches the
	-- Disconnect below inside the same resumption cycle that queued every
	-- MessageOut, and all of it is thrown away, while a chunk that DOES yield
	-- crosses a resumption point mid-run and keeps some, which is why this fails
	-- intermittently rather than obviously. task.wait is itself a resumption
	-- point, so one is enough to flush the queue.
	--   create.roblox.com/docs/scripting/events/deferred
	--
	-- Yielding here is safe for the same reason writeSource's is: tool dispatch
	-- runs from onComplete at message_stop, after the stream has delivered
	-- everything.
	pcall(task.wait)
	-- ponytail: the listener comes down as soon as require returns, so output
	-- from a task the chunk spawned that errors LATER is still lost. Catching
	-- that needs a session-long buffer read on the next turn, see FuturePlans.
	if listener then
		local connection = listener :: RBXScriptConnection
		pcall(function()
			connection:Disconnect()
		end)
	end

	-- Destroy in every path, including a syntax error inside require.
	pcall(function()
		module:Destroy()
	end)

	-- Both output blocks cap the same way, and used to say so twice.
	local function appendCapped(lines: { string }, heading: string, from: { string })
		if #from == 0 then
			return
		end
		table.insert(lines, heading)
		for index, line in ipairs(from) do
			if index > MAX_OUTPUT_LINES then
				table.insert(lines, string.format("… %d more lines", #from - MAX_OUTPUT_LINES))
				break
			end
			table.insert(lines, line)
		end
	end

	-- Deliberately "during this call" and not "by your code": a playtest or
	-- another plugin printing at the same moment lands here too, and the heading
	-- must not claim an origin it cannot check.
	local function appendEscaped(lines: { string })
		appendCapped(lines, "--- also printed during this call (not captured by run) ---", escaped)
	end

	if not ranOk then
		-- A compile error never reaches the pcall inside the chunk, so it lands
		-- here with a line number counted from the top of the generated file.
		local message = tostring(requireErr):gsub(":(%d+):", function(digits)
			return ":" .. tostring((tonumber(digits) :: number) - PROLOGUE_LINES) .. ":"
		end)
		-- Carried on the failure path too: when a require blows up, what the
		-- module managed to print on the way down is usually the reason.
		local failure = { message }
		appendEscaped(failure)
		return nil, table.concat(failure, "\n")
	end

	if type(result) ~= "table" then
		return nil, "harness returned an unexpected value — did the code redefine `return`?"
	end

	-- Which of the modules this chunk required were served from a cache entry
	-- that predates an edit. Edit-mode require never re-runs a module, so those
	-- calls returned the OLD code and the run's result is about code that is no
	-- longer there, the silent wrong answer this whole thing exists to name.
	--
	-- Mark the first require of each module as we go: that is when the entry was
	-- populated. Anything already marked keeps its original mark.
	local stale: { string } = {}
	local now = os.time()
	for _, inst in ipairs(result.required or {}) do
		if typeof(inst) == "Instance" then
			local first = requiredAt[inst]
			if not first then
				requiredAt[inst] = now
			else
				local edited = Fs.mtime(inst)
				if edited and edited > first then
					stale[#stale + 1] = instancePath(inst)
				end
			end
		end
	end

	local lines: { string } = {}
	table.insert(lines, string.format("ran in %.2f ms", (result.elapsed or 0) * 1000))

	appendCapped(lines, "--- output ---", result.out or {})
	appendEscaped(lines)

	-- ret is packed, so `return a, b` shows both and `return nil, "why"` shows
	-- the reason rather than just the nil. n is carried explicitly because a
	-- trailing nil is a real return value and # would not see it.
	local returned = result.ret or { n = 0 }
	if result.ok then
		if returned.n > 0 then
			local parts: { string } = {}
			for i = 1, returned.n do
				parts[i] = describe(returned[i])
			end
			table.insert(lines, "--- returned ---")
			table.insert(lines, table.concat(parts, ", "))
		end
	else
		local message = tostring(returned[1]):gsub(":(%d+):", function(digits)
			return ":" .. tostring((tonumber(digits) :: number) - PROLOGUE_LINES) .. ":"
		end)
		table.insert(lines, "--- error ---")
		table.insert(lines, message)
	end

	-- Last, so it reads as a caveat on everything above it rather than as part of
	-- the result. Absent entirely when nothing is stale.
	if #stale > 0 then
		-- Said ONCE, above the list, and without the engine lesson. This used to
		-- repeat a 45-word explanation of the module cache per stale entry, so
		-- three stale modules paid for it three times. What the caller needs is
		-- which paths are stale and what to call; WHY the cache behaves that way
		-- changes nothing it would do differently.
		table.insert(lines, "--- stale ---")
		table.insert(lines, "edited since this session first loaded them, so the run above used " ..
			"the old copy. `reload(<path>)` runs the current one:")
		for _, path in ipairs(stale) do
			table.insert(lines, "  " .. path)
		end
	end

	return table.concat(lines, "\n"), nil
end


-- Run a script by path. The ONLY way in from the tool.
--
-- There used to be a `code` parameter beside this one, and it was removed
-- because the model would not stop rebuilding this function inside it: read
-- `.Source`, loadstring it, pcall it, print the result. That hand-rolled version
-- is not merely wasteful, it is wrong. `.Source` is not the editor buffer, so a
-- file with unsaved edits gets tested in its old form and reports a pass. The
-- fix is not a better description, it is not offering the worse mechanism.
--
-- The source is inlined after the PROLOGUE, which is the point rather than an
-- accident: the file's own print/warn land in __out, an error on file line N
-- reports line N, and the require cache is never touched so there is no clone
-- and nothing to go stale. What it costs is `script`, which refers to the
-- generated module and not to the file, unavoidable either way since edit-mode
-- require cannot run a module twice without cloning it.
function Exec.run(self: any, path: string?): (string?, string?)
	if not path or path == "" then
		return nil, "run needs a path to a script. Write one to /ServerStorage/tmp first"
	end
	local target, resolveErr = self:resolve(path)
	if not target then return nil, resolveErr end
	if not isScript(target) then
		return nil, "not a script: " .. instancePath(target)
	end
	local source = getSource(target)
	if not source or source:match("^%s*$") then
		return nil, "empty script: " .. instancePath(target)
	end
	return runSource(self, source)
end

function Exec.selfTest(probeTerm: any): (boolean, string?)
	-- The line-offset invariant, and the cheapest check in this file. Every
	-- PROLOGUE entry is one physical line because PROLOGUE_LINES is #PROLOGUE and
	-- nothing else, a two-line entry shifts every error line number `run` ever
	-- reports, silently, and in the direction that sends the agent to edit the
	-- wrong line. Checked without executing anything, so it runs on every start.
	for index, entry in ipairs(PROLOGUE) do
		if entry:find("\n") then
			return false, string.format(
				"PROLOGUE entry %d spans more than one line, which breaks every reported error line",
				index)
		end
	end
	if PROLOGUE_LINES ~= #PROLOGUE then
		return false, "PROLOGUE_LINES no longer matches #PROLOGUE"
	end

	if runGuard and runGuard() then
		local probe = Instance.new("ModuleScript")
		probe.Name = "ClaudeReloadProbe"
		probe.Source = "return 1"
		probe.Parent = ServerStorage
		local out, runErr = runSource(probeTerm, string.format([[
local m = game:GetService("ServerStorage"):FindFirstChild(%q)
local a = require(m)
m.Source = "return 2"
local b = require(m)
local c = reload(m)
return tostring(a) .. "/" .. tostring(b) .. "/" .. tostring(c)
]], probe.Name))
		probe:Destroy()
		if not out then
			return false, "reload probe failed to run: " .. tostring(runErr)
		end
		if not out:find("1/1/2", 1, true) then
			return false, "reload did not defeat the require cache — wanted 1/1/2 in:\n" .. out
		end

		-- run BY PATH, and the property that makes it worth having: the file's
		-- source is inlined where `code` would go, so an error on file line 2
		-- must still report line 2. If the PROLOGUE offset ever stops matching,
		-- this is where it shows up as a number rather than as the agent
		-- editing the wrong line.
		local byPath = Instance.new("ModuleScript")
		byPath.Name = "ClaudeRunPathProbe"
		-- Not a bare number: "ran in 0.07 ms" heads every result, so `find("7")`
		-- would pass whether or not the print ever landed.
		byPath.Source = "print(\"probe-printed\")\nerror(\"boom\")"
		byPath.Parent = ServerStorage
		local term = probeTerm
		local pathOut, pathErr = Exec.run(term, "/ServerStorage/" .. byPath.Name)
		local noPath = Exec.run(term, nil)
		byPath:Destroy()
		if not pathOut then
			return false, "run by path failed: " .. tostring(pathErr)
		end
		if not pathOut:find("probe-printed", 1, true) then
			return false, "run by path did not capture the file's own print:\n" .. pathOut
		end
		if not pathOut:find(":2: boom", 1, true) then
			return false, "run by path mis-mapped the error line — wanted :2: in:\n" .. pathOut
		end
		if noPath then
			return false, "run accepted a missing path"
		end

		-- Every value, not just the first. The nil in the middle is the point:
		-- `return nil, "why"` is the commonest shape in Luau and used to come
		-- back as nothing at all.
		local multi = runSource(term, "return 1, nil, \"three\"")
		if not multi or not multi:find("1, nil, three", 1, true) then
			return false, "run dropped values past the first:\n" .. tostring(multi)
		end
	end

	return true
end

return Exec
