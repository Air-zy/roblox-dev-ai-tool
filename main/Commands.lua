-- Commands.luau: slash commands.
--
-- SLASH_COMMANDS is the single source of truth: it drives the autocomplete
-- dropdown, /help, and the dispatch table below, so adding a command in one
-- place can't leave the other two stale.

-- Commands sits at the root rather than in a folder because it is the glue: it
-- reaches into every layer by definition, so filing it under one of them would
-- be picking a side arbitrarily.
local agent = script.Parent:WaitForChild("agent")
local ui = script.Parent:WaitForChild("ui")


local Console = require(ui:WaitForChild("Console"))
local Settings = require(ui:WaitForChild("Settings"))
local Sessions = require(ui:WaitForChild("Sessions"))
local Provider = require(agent:WaitForChild("Provider"))
local Agent = require(agent:WaitForChild("Agent"))
local Terminal = require(script.Parent:WaitForChild("fs"):WaitForChild("Terminal"))
local Tools = require(agent:WaitForChild("Tools"))
-- The four the self-test runner needs and nothing else did. Commands already
-- reaches into every layer by definition, which is the reason the runner lives
-- here rather than being handed in as a fifth callback from main.
local Markdown = require(ui:WaitForChild("Markdown"))
local Find = require(ui:WaitForChild("Find"))
local Props = require(script.Parent:WaitForChild("studio"):WaitForChild("Props"))
local Sha256 = require(script.Parent:WaitForChild("util"):WaitForChild("Sha256")) :: any

local Commands = {}

local term: any = nil
local openSettings: ((boolean?) -> ())? = nil
local openFind: ((boolean?, string?) -> ())? = nil
local toggleShell: ((boolean?) -> ())? = nil

function Commands.Initialize(
	terminal: any,
	settingsToggle: ((boolean?) -> ())?,
	findToggle: ((boolean?, string?) -> ())?,
	shellToggle: ((boolean?) -> ())?
)
	term = terminal
	openSettings = settingsToggle
	openFind = findToggle
	toggleShell = shellToggle
end

-- One line through the shell, with its output appended. Shared by `/sh <cmd>`
-- and by shell mode, which are the same act with and without a prefix — two
-- copies is how the one that prints blank lines comes to differ from the one
-- that does not.
--
-- The ECHO is deliberately not here. Commands.handle already prints the slash
-- line it was given, and shell mode prints its own; doing it in both places is
-- how `/sh ls` came to show up twice.
function Commands.runShell(line: string)
	for out in term:shell(line):gmatch("[^\n]+") do
		Console.appendLine(out, "info")
	end
end

-- Handlers
local handlers: { [string]: (string?, string) -> () } = {}

handlers["/help"] = function()
	Console.appendLine("Commands:", "info")
	for _, entry in ipairs(Commands.SLASH_COMMANDS) do
		Console.appendLine(string.format("  %-14s %s", entry.cmd, entry.desc), "info")
	end
	Console.appendLine("", "info")
	Console.appendLine("tools:", "info")
	-- Both lines are derived, not hand-written, which is how the old list ended
	-- up advertising eleven shell commands out of twenty-six, and why the tool
	-- line now comes from the registry rather than a literal that goes stale the
	-- moment someone drops a file into tools/.
	Console.appendLine("  bash   " .. table.concat(Terminal.COMMANDS, " "), "info")
	local others: { string } = {}
	for _, name in ipairs(Tools.names()) do
		if name ~= "bash" then
			others[#others + 1] = name
		end
	end
	Console.appendLine("  also   " .. table.concat(others, " ") ..
		"   (writes undoable with Ctrl+Z)", "info")
end

handlers["/login"] = function()
	if Provider.auth.isLoggedIn() then
		Console.appendLine("Already logged in. Use /logout first.", "info")
		return
	end
	Console.appendLine("Starting OAuth login…", "info")
	task.spawn(function()
		local ok, result = pcall(Provider.auth.startLogin)
		if not ok then
			Console.appendLine("Failed: " .. tostring(result), "error")
			return
		end
		Console.appendLine("Open this URL in your browser:", "info")
		Console.appendLine((result :: any).authorizeUrl, "info")
		Console.appendLine("Then: /code YOUR_CODE", "info")
	end)
end

handlers["/code"] = function(_, raw)
	-- Auth codes can contain spaces, so take everything after the command name
	-- rather than just the first word.
	local code = raw:match("^/code%s+(.+)$")
	if not code or code == "" then
		Console.appendLine("Usage: /code <paste-code-here>", "error")
		return
	end
	Console.appendLine("Exchanging code…", "info")
	task.spawn(function()
		local ok, err = Provider.auth.completeLogin(code)
		if ok then
			Console.appendLine("Login successful!", "assistant")
			-- A provider whose model list needs the credential can only fetch it
			-- now. Without this the picker keeps whatever stub it started with
			-- until the next Studio launch, which reads as a broken roster rather
			-- than an unfetched one. Spawned and unwaited: nothing on screen
			-- depends on it, and a provider with a hardcoded list has no hook here
			-- to call.
			local wire = Provider.wire :: any
			if wire and wire.refreshModels then
				task.spawn(wire.refreshModels)
			end
		else
			Console.appendLine("Login failed: " .. tostring(err), "error")
		end
	end)
end

handlers["/logout"] = function()
	Provider.auth.logout()
	Agent.reset()
	Console.appendLine("Logged out.", "info")
end

handlers["/status"] = function()
	if Provider.auth.isLoggedIn() then
		local expiry = Provider.auth.tokenExpiry()
		local expiryText = "unknown"
		if expiry then
			expiryText = string.format("~%d min left", math.max(0, math.floor((expiry - os.time()) / 60)))
		end
		Console.appendLine(string.format("Logged in. Token %s.", expiryText), "info")
	else
		Console.appendLine("Not logged in. Use /login.", "info")
	end
	Console.appendLine("Provider: " .. Provider.label(), "info")
	Console.appendLine("Model: " .. Settings.model(), "info")
	Console.appendLine("Effort: " .. Settings.effortName(), "info")
	Console.appendLine("CWD: " .. term:pwd(), "info")
end

handlers["/model"] = function(arg)
	if not arg or arg == "" then
		for _, entry in ipairs(Provider.wire.MODELS) do
			local marker = (entry.id == Settings.model()) and " *" or ""
			Console.appendLine(string.format("  %-30s %s%s", entry.id, entry.label, marker), "info")
		end
		return
	end
	for _, entry in ipairs(Provider.wire.MODELS) do
		if entry.id == arg or entry.id:find(arg, 1, true) then
			Settings.setModel(entry.id)
			Console.appendLine("Model: " .. entry.id, "info")
			return
		end
	end
	-- An id the list has never heard of, so a model released after this build
	-- is still reachable by name. The provider decides what one of its ids looks
	-- like; OpenRouter alone has several hundred, far too many to list.
	local wire = Provider.wire
	if wire.acceptsModelId and wire.acceptsModelId(arg) then
		Settings.setModel(arg)
		Console.appendLine("Model: " .. arg, "info")
	else
		Console.appendLine("Unknown model: " .. arg, "error")
	end
end

-- Switching providers resets the agent, and has to: the conversation in memory
-- is shaped by whoever produced it, down to thinking-block signatures only that
-- provider can read.
handlers["/provider"] = function(arg)
	if not arg or arg == "" then
		for _, entry in ipairs(Provider.list()) do
			local marker = (entry.id == Provider.id) and " *" or ""
			Console.appendLine(string.format("  %-12s %s (%s)%s",
				entry.id, entry.label, entry.hint, marker), "info")
		end
		Console.appendLine("Usage: /provider <name>", "info")
		return
	end
	if arg == Provider.id then
		Console.appendLine("Already on " .. Provider.label(arg) .. ".", "info")
		return
	end
	if not Provider.use(arg) then
		Console.appendLine("Unknown provider: " .. arg, "error")
		return
	end
	Settings.reloadModel()
	-- A new session rather than a wipe: the old conversation stays on disk and
	-- opens again the moment you switch back.
	Sessions.new()
	Console.appendLine(string.format("Provider: %s · model %s",
		Provider.label(arg), Settings.model()), "assistant")
	if not Provider.auth.isLoggedIn() then
		Console.appendLine("Not logged in for this provider. Use /login.", "info")
	end
end

-- Wipes the stored session too, not just the screen: leaving the saved copy
-- behind would have the next open restore what was just cleared.
handlers["/clear"] = function()
	Sessions.clear()
end

-- The same terminal Claude uses, and now the same powers. The whole line goes
-- through Terminal:shell, so quoting, flags, globs and `;` all behave exactly as
-- they do for Claude, there is no second parser here to drift from the first.
--
-- It was read-only until it was not. The reason given was that a mutation should
-- arrive through Claude carrying an undo recording, and withUndo turned out to
-- live in the handlers rather than on Claude's path, so a write from here was
-- always recorded the same. What was left was that changes stayed in the
-- transcript — worth something, but not worth the owner of the place having less
-- reach over it than the agent working on it, when Explorer already hands them a
-- Delete key with no transcript at all.
handlers["/sh"] = function(_, raw)
	local rest = raw:match("^/sh%s+(.+)$")
	-- Bare `/sh` used to be a usage error. It stays in the shell instead: every
	-- line typed after it goes to the terminal until `exit`, which is the whole
	-- of what a shell panel would have been. No second text box, no second
	-- scrollback, no second history — the input row and the console already are
	-- both of those, and a plugin widget delivers no arrow keys to build a third.
	if not rest then
		if toggleShell then toggleShell() end
		return
	end
	Commands.runShell(rest)
end

-- Every module's selfTest, run on demand.
--
-- These all used to run in main's startup task: roughly 1800 lines of test code,
-- some thirty Instances created and destroyed, and half a dozen plugin-setting
-- writes, on the frame the widget opens. That was the startup lag, and it bought
-- a check at the one moment nothing had changed since the last time it passed.
--
-- Nothing is deleted, and the set is not trimmed either. A test that never runs
-- rots, so this is one command away rather than gone — and running a "cheap
-- subset" is the version that quietly stops covering things while still looking
-- like it covers them.
--
-- Terminal's entry pulls in Shell, and Shell's pulls in Regex, Sed and Git, so
-- four of the biggest are behind one name here.
local SELF_TESTS: { { name: string, run: () -> (boolean, string?) } } = {
	{ name = "sha256",    run = Sha256.selfTest },
	{ name = "markdown",  run = Markdown.selfTest },
	{ name = "terminal",  run = Terminal.selfTest },
	{ name = "props",     run = Props.selfTest },
	{ name = "agent",     run = Agent.selfTest },
	{ name = "provider",  run = Provider.selfTest },
	{ name = "sessions",  run = Sessions.selfTest },
	{ name = "find",      run = Find.selfTest },
	-- Last, and on its own line in the code as well as in the run: its check ends
	-- by clearing the console, because what it is testing IS the console. The
	-- conversation is redrawn from storage straight after.
	{ name = "console",   run = Console.selfTest },
}

handlers["/selftest"] = function()
	local failures: { string } = {}
	local passed = 0
	for _, entry in ipairs(SELF_TESTS) do
		-- pcall, because a self-test that THROWS would otherwise take the rest of
		-- the suite with it and report nothing at all.
		local ran, ok, err = pcall(entry.run)
		if not ran then
			failures[#failures + 1] = entry.name .. " threw: " .. tostring(ok)
		elseif not ok then
			failures[#failures + 1] = entry.name .. ": " .. tostring(err)
		else
			passed += 1
		end
	end
	-- console's test leaves the screen empty; put the conversation back before
	-- anything is printed into it.
	Sessions.restoreLast()
	if #failures == 0 then
		Console.appendLine(string.format("selftest: %d passed", passed), "info")
		return
	end
	Console.appendLine(string.format("selftest: %d passed, %d FAILED",
		passed, #failures), "error")
	for _, note in ipairs(failures) do
		Console.appendLine("  " .. note, "error")
	end
end

handlers["/settings"] = function()
	if openSettings then openSettings(true) end
end

-- The find panel has a button and Shift+Esc; this is the third way in, and the
-- only one that carries the query with it. Studio hands a plugin widget no key
-- events at all while one of its text boxes is taking them, so a command typed
-- into that box is the most reliable trigger there is.
handlers["/find"] = function(_, raw)
	local query = raw:match("^/find%s+(.+)$")
	if openFind then openFind(true, query) end
end

-- Registry + dispatch
Commands.SLASH_COMMANDS = {
	{ cmd = "/login",    desc = "Start OAuth login flow" },
	{ cmd = "/code",     desc = "Complete login with pasted code" },
	{ cmd = "/logout",   desc = "Clear stored tokens" },
	{ cmd = "/status",   desc = "Show login, model, effort, current path" },
	{ cmd = "/model",    desc = "Switch model" },
	{ cmd = "/provider", desc = "Switch provider" },
	{ cmd = "/settings", desc = "Open the settings panel" },
	{ cmd = "/selftest", desc = "Run every module's self-test (redraws the console)" },
	{ cmd = "/sh",       desc = "Run a terminal command, or bare to stay in the shell" },
	{ cmd = "/find",     desc = "Search this chat, thinking included" },
	{ cmd = "/clear",    desc = "Clear output + conversation" },
	{ cmd = "/help",     desc = "Show all commands" },
}

-- Returns true if the input was a slash command (handled or not).
function Commands.handle(raw: string): boolean
	local trimmed = raw:match("^%s*(.-)%s*$") or raw
	if trimmed:sub(1, 1) ~= "/" then
		return false
	end

	Console.appendLine(trimmed, "cmd")

	local cmd = trimmed:match("^(%S+)") or ""
	local arg = trimmed:match("^%S+%s+(%S+)")

	local handler = handlers[cmd]
	if handler then
		handler(arg, trimmed)
	else
		Console.appendLine("Unknown command: " .. cmd .. " (try /help)", "error")
	end
	return true
end

return Commands
