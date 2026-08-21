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
local Auth = Provider.auth
local Wire = Provider.wire
local Agent = require(agent:WaitForChild("Agent"))
local Terminal = require(script.Parent:WaitForChild("fs"):WaitForChild("Terminal"))
local Tools = require(agent:WaitForChild("Tools"))

local Commands = {}

local term: any = nil
local openSettings: ((boolean?) -> ())? = nil
local openFind: ((boolean?, string?) -> ())? = nil

function Commands.Initialize(
	terminal: any,
	settingsToggle: ((boolean?) -> ())?,
	findToggle: ((boolean?, string?) -> ())?
)
	term = terminal
	openSettings = settingsToggle
	openFind = findToggle
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
	if Auth.isLoggedIn() then
		Console.appendLine("Already logged in. Use /logout first.", "info")
		return
	end
	Console.appendLine("Starting OAuth login…", "info")
	task.spawn(function()
		local ok, result = pcall(Auth.startLogin)
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
		local ok, err = Auth.completeLogin(code)
		if ok then
			Console.appendLine("Login successful!", "assistant")
		else
			Console.appendLine("Login failed: " .. tostring(err), "error")
		end
	end)
end

handlers["/logout"] = function()
	Auth.logout()
	Agent.reset()
	Console.appendLine("Logged out.", "info")
end

handlers["/status"] = function()
	if Auth.isLoggedIn() then
		local expiry = Auth.tokenExpiry()
		local expiryText = "unknown"
		if expiry then
			expiryText = string.format("~%d min left", math.max(0, math.floor((expiry - os.time()) / 60)))
		end
		Console.appendLine(string.format("Logged in. Token %s.", expiryText), "info")
	else
		Console.appendLine("Not logged in. Use /login.", "info")
	end
	Console.appendLine("Model: " .. Settings.model(), "info")
	Console.appendLine("Effort: " .. Settings.effortName(), "info")
	Console.appendLine("CWD: " .. term:pwd(), "info")
end

handlers["/model"] = function(arg)
	if not arg or arg == "" then
		for _, entry in ipairs(Wire.MODELS) do
			local marker = (entry.id == Settings.model()) and " *" or ""
			Console.appendLine(string.format("  %-30s %s%s", entry.id, entry.label, marker), "info")
		end
		return
	end
	for _, entry in ipairs(Wire.MODELS) do
		if entry.id == arg or entry.id:find(arg, 1, true) then
			Settings.setModel(entry.id)
			Console.appendLine("Model: " .. entry.id, "info")
			return
		end
	end
	if arg:find("claude-", 1, true) then
		Settings.setModel(arg)
		Console.appendLine("Model: " .. arg, "info")
	else
		Console.appendLine("Unknown model: " .. arg, "error")
	end
end

-- Wipes the stored session too, not just the screen: leaving the saved copy
-- behind would have the next open restore what was just cleared.
handlers["/clear"] = function()
	Sessions.clear()
end

-- Read-only passthrough to the terminal Claude uses. The whole line goes through
-- Terminal:shell, so quoting, flags, globs and `;` all behave exactly as they do
-- for Claude, there is no second parser here to drift from the first.
--
-- The read-only check lives in Terminal, next to the handler table that knows
-- which commands mutate, and it is applied per command rather than per line, so
-- `pwd; rm /Workspace` cannot smuggle a write past it. Keeping writes out means
-- every mutation still arrives through Claude with an undo recording.
handlers["/sh"] = function(_, raw)
	local rest = raw:match("^/sh%s+(.+)$")
	if not rest then
		Console.appendLine("Usage: /sh <command>   e.g. /sh ls /Workspace", "error")
		return
	end
	for line in term:shell(rest, true):gmatch("[^\n]+") do
		Console.appendLine(line, "info")
	end
end

handlers["/settings"] = function()
	if openSettings then openSettings(true) end
end

-- The find panel has a button and a Ctrl+F, and neither can help you while the
-- input box has focus: Studio hands a plugin widget no key events at all while
-- one of its text boxes is taking them. This is the trigger that works from
-- inside the box, which is where you already are.
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
	{ cmd = "/settings", desc = "Open the settings panel" },
	{ cmd = "/sh",       desc = "Run a read-only terminal command" },
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
