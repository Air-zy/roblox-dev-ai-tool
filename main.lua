--!strict
-- Claude Code for Roblox — plugin entry point.
--
-- This file does plugin setup and nothing else: widget, toolbar, the input row,
-- and wiring the modules together. Rendering lives in Console, formatting in
-- Markdown, preferences in Settings, the conversation in Agent, slash commands
-- in Commands, and the DataModel browser in Terminal.

assert(plugin ~= nil, "This script must run as a Roblox Studio plugin (the `plugin` global is missing).")

local RunService = game:GetService("RunService")

-- Modules are grouped by what they are, not listed flat. A module only ever
-- reaches for a folder it does not live in when it genuinely crosses layers,
-- which is why this is the only file that names all four.
local agent = script:WaitForChild("agent")
local auth  = script:WaitForChild("auth")
local fs    = script:WaitForChild("fs")
local ui    = script:WaitForChild("ui")

local Sha256   = require(auth:WaitForChild("Sha256"))   :: any
local OAuth    = require(auth:WaitForChild("OAuth"))    :: any
local Claude   = require(agent:WaitForChild("Claude"))  :: any
local Props    = require(fs:WaitForChild("Props"))      :: any
local Terminal = require(fs:WaitForChild("Terminal"))   :: any
local Theme    = require(ui:WaitForChild("Theme"))
local Markdown = require(ui:WaitForChild("Markdown"))
local Console  = require(ui:WaitForChild("Console"))
local Settings = require(ui:WaitForChild("Settings"))
local Agent    = require(agent:WaitForChild("Agent"))
local Commands = require(script:WaitForChild("Commands"))

local make = Theme.make

OAuth.Initialize(plugin)
Claude.Initialize(OAuth)
Settings.Initialize(plugin)

local term = Terminal.new(game)
-- Terminal asks this before executing anything, rather than importing Settings
-- itself; keeps the dependency pointing one way.
Terminal.setRunGuard(Settings.allowRun)

-- =============================================================================
-- Widget + toolbar
-- =============================================================================
-- Float, not Bottom: there is no dock state for the centre viewport — Studio
-- only docks to the four edges — so a floating window over the 3D view is as
-- close as the API gets to "where the game world is".
--
-- initEnabled is FALSE. It is not just a first-run preference: a widget created
-- with initEnabled true re-enables itself during playtest initialisation
-- regardless of its saved state, which is half of why this kept appearing on
-- Play. The other half is handled below.
--
-- The GUI id carries a suffix because Studio remembers dock position per id and
-- that memory outranks InitialDockState. Under the old id the widget would stay
-- docked to the bottom no matter what this says.
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	false, false,
	900, 320,
	400, 140
)
local widget = plugin:CreateDockWidgetPluginGuiAsync("ClaudeCodeTerminalFloat", widgetInfo)
widget.Title = "Claude Code"
-- DockWidgetPluginGui defaults to ZIndexBehavior.Global, where ZIndex is compared
-- across the entire GUI rather than among siblings. Under Global, a child that
-- doesn't set ZIndex sits at 1 and renders BEHIND any ancestor with a higher
-- value — which is why the settings card hid its own contents. Sibling makes
-- layering follow the hierarchy, so a child always draws above its parent and no
-- widget has to hand-pick a number.
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local toolbar = plugin:CreateToolbar("Claude Code")
local toggleButton = toolbar:CreateButton("ClaudeCodeToggle", "Claude Code", "")
toggleButton.Click:Connect(function()
	if RunService:IsRunning() then return end
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)
toggleButton:SetActive(widget.Enabled)

-- Edit-mode only. The plugin keeps running through a playtest — that is why the
-- widget used to sit over the game — so the run state has to be watched, not
-- just read once at load. IsEdit() is the inverse of IsRunning() except while
-- paused, when both are false; IsRunning() is the one that stays true through a
-- pause, which is what "still playtesting" means here.
--
-- Whether the panel was open is remembered so Stop puts it back exactly as it
-- was, rather than leaving the user to reopen it every time.
-- ponytail: polled once a second because Studio exposes no run-state signal.
-- Swap it for an event the day one exists.
local restoreAfterRun = false
local function syncRunState()
	if RunService:IsRunning() then
		if widget.Enabled then
			restoreAfterRun = true
			widget.Enabled = false
		end
	elseif restoreAfterRun then
		restoreAfterRun = false
		widget.Enabled = true
	end
end
syncRunState()

local unloading = false
plugin.Unloading:Connect(function() unloading = true end)
task.spawn(function()
	while not unloading do
		task.wait(1)
		syncRunState()
	end
end)

-- =============================================================================
-- Chrome
-- =============================================================================
local root = make("Frame", {
	Name = "Root",
	Parent = widget,
	BackgroundColor3 = Theme.BG_DARK,
	BorderSizePixel = 0,
	Size = UDim2.fromScale(1, 1),
})
make("UIListLayout", { Parent = root, SortOrder = Enum.SortOrder.LayoutOrder })

local headerBar = make("Frame", {
	Name = "Header",
	Parent = root,
	BackgroundColor3 = Theme.BG_DARK,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 32),
	LayoutOrder = 1,
})
make("TextLabel", {
	Parent = headerBar,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, -80, 1, 0),
	Position = UDim2.new(0, 12, 0, 0),
	FontFace = Theme.SANS_BOLD,
	TextSize = 13,
	TextColor3 = Theme.TEXT_MED,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Claude Code",
})
local statusLabel = make("TextLabel", {
	Name = "Status",
	Parent = headerBar,
	BackgroundTransparency = 1,
	Size = UDim2.new(0, 220, 1, 0),
	Position = UDim2.new(1, -256, 0, 0),
	FontFace = Theme.SANS,
	TextSize = 11,
	TextColor3 = Theme.TEXT_LO,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextXAlignment = Enum.TextXAlignment.Right,
	Text = "",
})
local settingsButton = make("TextButton", {
	Name = "SettingsButton",
	Parent = headerBar,
	BackgroundTransparency = 1,
	Size = UDim2.new(0, 32, 1, 0),
	Position = UDim2.new(1, -36, 0, 0),
	FontFace = Theme.SANS,
	TextSize = 16,
	TextColor3 = Theme.TEXT_MED,
	Text = "⚙",
	AutoButtonColor = false,
})
make("Frame", {
	Parent = headerBar,
	BackgroundColor3 = Theme.BORDER,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 1),
	Position = UDim2.new(0, 0, 1, -1),
})

local outputFrame = Console.mount(root, 2)

-- Grows with the text now that Shift+Enter can add lines, capped so a pasted
-- wall of code cannot eat the console. The output frame is resized from this
-- row's real height below rather than from the old hardcoded 64.
local inputRow = make("Frame", {
	Name = "InputRow",
	Parent = root,
	BackgroundColor3 = Theme.BG_INPUT,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 32),
	AutomaticSize = Enum.AutomaticSize.Y,
	LayoutOrder = 3,
})
make("UISizeConstraint", {
	Parent = inputRow,
	MinSize = Vector2.new(0, 32),
	MaxSize = Vector2.new(math.huge, 132),
})
make("Frame", {
	Parent = inputRow,
	BackgroundColor3 = Theme.BORDER,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 1),
})
-- Pinned to the top rather than centred: the row grows downward now, and a
-- prompt caret that drifts to the middle of a six-line message reads as a bug.
make("TextLabel", {
	Parent = inputRow,
	BackgroundTransparency = 1,
	Size = UDim2.new(0, 24, 0, 32),
	FontFace = Theme.MONO,
	TextSize = 14,
	TextColor3 = Theme.ACCENT,
	TextXAlignment = Enum.TextXAlignment.Center,
	TextYAlignment = Enum.TextYAlignment.Center,
	Text = "❯",
})
local stopButton = make("TextButton", {
	Name = "StopButton",
	Parent = inputRow,
	BackgroundColor3 = Theme.ACCENT_HI,
	BorderSizePixel = 0,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -8, 0.5, 0),
	Size = UDim2.new(0, 62, 0, 22),
	FontFace = Theme.SANS_BOLD,
	TextSize = 11,
	TextColor3 = Theme.TEXT_HI,
	Text = "■ Stop",
	AutoButtonColor = true,
	Visible = false,
})
make("UICorner", { Parent = stopButton, CornerRadius = UDim.new(0, 4) })
stopButton.MouseButton1Click:Connect(function()
	Agent.stop()
end)

local inputBox = make("TextBox", {
	Name = "Input",
	Parent = inputRow,
	BackgroundTransparency = 1,
	-- Leaves room for the Stop button, which only appears while streaming.
	Size = UDim2.new(1, -104, 0, 32),
	AutomaticSize = Enum.AutomaticSize.Y,
	Position = UDim2.new(0, 24, 0, 0),
	FontFace = Theme.SANS,
	TextSize = Theme.TEXT_SIZE,
	TextColor3 = Theme.TEXT_HI,
	-- MultiLine is what lets Shift+Enter add a line. It also means Enter no
	-- longer fires FocusLost(enterPressed): the TextBox keeps the keypress and
	-- inserts a newline instead. Sending is therefore detected from the text
	-- changing, not from the key — see the Text handler further down.
	MultiLine = true,
	ClearTextOnFocus = false,
	Text = "",
	PlaceholderText = "Message Claude…  ( / for commands · shift+enter for a new line )",
	PlaceholderColor3 = Theme.TEXT_LO,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
})
make("UIPadding", { Parent = inputBox, PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) })

-- The output frame used to assume a 32px header plus a 32px input row. The row
-- is elastic now, so read its real height instead of hardcoding the sum.
--
-- Guarded on the height actually changing. AbsoluteSize fires on width too, and
-- on recomputes that land on the same value, so an unguarded version reassigned
-- the output frame's size on every keystroke — and because that frame is a
-- ScrollingFrame with AutomaticCanvasSize, each assignment relaid out the entire
-- console behind it. That was the stutter while typing, not a Roblox artefact.
local lastInputHeight = -1
local function fitOutput()
	local height = inputRow.AbsoluteSize.Y
	if height == lastInputHeight then return end
	lastInputHeight = height
	outputFrame.Size = UDim2.new(1, 0, 1, -(32 + height))
end
inputRow:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitOutput)
fitOutput()

-- =============================================================================
-- Settings popup
-- =============================================================================
-- Settings shouldn't know about OAuth, the Terminal or the Agent, so the entry
-- point supplies the status rows.

-- The status value column truncates at end, so a raw token count would hide the
-- output half of the row. 1.2M / 34.5k / 812.
local function compact(n: number): string
	if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if n >= 1000 then return string.format("%.1fk", n / 1000) end
	return tostring(n)
end

-- Plan usage ------------------------------------------------------------------
-- Held between openings so the bars are already on screen while a refresh is in
-- flight, and so a rate-limited fetch (the usage endpoint has its own limit)
-- leaves the last known numbers up instead of blanking them.
local usageWindows: { [string]: any }? = nil
local usageError: string? = nil
local usageFetchedAt = 0
local usageInFlight = false

-- resets_at comes back as ISO 8601 with microseconds and a numeric offset
-- ("2026-08-04T06:50:08.843137+00:00"), which DateTime.fromIsoDate rejects.
-- Pull the fields out and rebuild the instant, applying the offset by hand.
local function isoToEpoch(iso: string): number?
	local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then return nil end
	local ok, moment = pcall(function()
		return DateTime.fromUniversalTime(
			tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number,
			tonumber(h) :: number, tonumber(mi) :: number, tonumber(s) :: number
		)
	end)
	if not ok then return nil end
	local epoch = moment.UnixTimestamp
	local sign, offH, offM = iso:match("([%+%-])(%d%d):(%d%d)$")
	if sign then
		local shift = (tonumber(offH) :: number) * 3600 + (tonumber(offM) :: number) * 60
		epoch += if sign == "+" then -shift else shift
	end
	return epoch
end

local function untilReset(resetsAt: any): string
	if type(resetsAt) == "string" then
		resetsAt = isoToEpoch(resetsAt)
	end
	if type(resetsAt) ~= "number" then return "" end
	local seconds = resetsAt - os.time()
	if seconds <= 0 then return "resets now" end
	if seconds < 3600 then return string.format("resets in %dm", math.floor(seconds / 60)) end
	if seconds < 86400 then
		return string.format("resets in %dh %dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
	end
	return string.format("resets in %dd %dh", math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
end

-- ponytail: the endpoint's utilization scale isn't documented, and both 0..1 and
-- 0..100 appear in the wild. Anything above 1 is read as a percentage. Drop the
-- branch once the live response settles it.
local function fraction(utilization: any): number?
	if type(utilization) ~= "number" then return nil end
	return math.clamp(if utilization > 1 then utilization / 100 else utilization, 0, 1)
end

local function usageRows(rows: { Settings.StatusRow })
	if not OAuth.isLoggedIn() then return end
	if not usageWindows then
		table.insert(rows, { label = "Plan usage", value = usageError or "loading…" })
		return
	end
	for _, window in ipairs({
		{ key = "five_hour", label = "Session (5h)" },
		{ key = "seven_day", label = "Weekly" },
	}) do
		local data = usageWindows[window.key]
		if type(data) == "table" then
			local used = fraction(data.utilization)
			if used then
				local age = usageError and " · stale" or ""
				table.insert(rows, {
					label = window.label,
					value = string.format("%d%% · %s%s", math.floor(used * 100 + 0.5), untilReset(data.resets_at), age),
					bar = used,
				})
			end
		end
	end
end

local toggleSettings, refreshSettings = Settings.mountPanel(widget, function(): { Settings.StatusRow }
	local rows: { Settings.StatusRow } = {}

	if OAuth.isLoggedIn() then
		local expiry = OAuth.tokenExpiry()
		local detail = "yes"
		if expiry then
			detail = string.format("yes · ~%d min", math.max(0, math.floor((expiry - os.time()) / 60)))
		end
		table.insert(rows, { label = "Signed in", value = detail })
	else
		table.insert(rows, { label = "Signed in", value = "no — /login" })
	end

	usageRows(rows)
	-- Model, effort, web search and run-code are NOT repeated here: each has a
	-- dropdown a few rows down showing the same value, and the console header
	-- already carries model · effort.
	table.insert(rows, { label = "Working dir", value = term:pwd() })
	table.insert(rows, { label = "Messages", value = tostring(#Agent.conversation()) })
	local usage = Agent.usage()
	table.insert(rows, {
		label = "Tokens",
		value = string.format("%s in · %s out", compact(usage.input), compact(usage.output)),
	})
	return rows
end)

-- The bars come from a network call, so they can't be produced inside the
-- synchronous status provider above. Fetch on open, redraw when it lands.
local USAGE_MAX_AGE = 60
local function refreshUsage()
	if usageInFlight or not OAuth.isLoggedIn() then return end
	if usageWindows and os.clock() - usageFetchedAt < USAGE_MAX_AGE then return end
	usageInFlight = true
	task.spawn(function()
		local windows, err = OAuth.fetchUsage()
		usageInFlight = false
		if windows then
			usageWindows = windows
			usageError = nil
			usageFetchedAt = os.clock()
		else
			-- Keep the previous bars; the message tells the row to mark them stale.
			usageError = err
		end
		refreshSettings()
	end)
end

settingsButton.MouseButton1Click:Connect(function()
	refreshUsage()
	toggleSettings(nil)
end)

local function refreshStatus()
	statusLabel.Text = string.format("%s · %s", Settings.model(), Settings.effortName():lower())
end
refreshStatus()

-- =============================================================================
-- Autocomplete dropdown
-- =============================================================================
local dropdown = make("Frame", {
	Name = "AutocompleteDropdown",
	Parent = widget,
	BackgroundColor3 = Theme.BG_INPUT,
	BorderColor3 = Theme.ACCENT,
	BorderSizePixel = 1,
	Size = UDim2.new(0, 320, 0, 0),
	Position = UDim2.new(0, 12, 1, -32),
	Visible = false,
	ZIndex = 40,
})
make("UIListLayout", { Parent = dropdown, SortOrder = Enum.SortOrder.LayoutOrder })
make("UIPadding", { Parent = dropdown, PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2) })

local dropdownButtons: { TextButton } = {}
local function updateDropdown(filter: string)
	for _, button in ipairs(dropdownButtons) do
		button:Destroy()
	end
	table.clear(dropdownButtons)

	local matches = {}
	for _, entry in ipairs(Commands.SLASH_COMMANDS) do
		if entry.cmd:sub(1, #filter):lower() == filter:lower() then
			table.insert(matches, entry)
		end
	end
	if #matches == 0 then
		dropdown.Visible = false
		return
	end

	for i, entry in ipairs(matches) do
		local button = make("TextButton", {
			Parent = dropdown,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 24),
			FontFace = Theme.MONO,
			TextSize = Theme.TEXT_SIZE,
			TextColor3 = Theme.TEXT_HI,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "  " .. entry.cmd .. string.rep(" ", math.max(2, 14 - #entry.cmd)) .. entry.desc,
			AutoButtonColor = true,
			LayoutOrder = i,
			ZIndex = 41,
		})
		button.MouseButton1Click:Connect(function()
			inputBox.Text = entry.cmd .. " "
			inputBox:CaptureFocus()
			dropdown.Visible = false
		end)
		table.insert(dropdownButtons, button)
	end

	local height = #matches * 24 + 4
	dropdown.Size = UDim2.new(0, 320, 0, height)
	-- Sits above the input row, whatever height the row currently is — it grows
	-- with the message, so the old hardcoded 32 would put the list on top of it.
	dropdown.Position = UDim2.new(0, 12, 1, -inputRow.AbsoluteSize.Y - height - 4)
	dropdown.Visible = true
end

inputBox:GetPropertyChangedSignal("Text"):Connect(function()
	local text = inputBox.Text
	if text:sub(1, 1) == "/" and not text:find(" ") then
		updateDropdown(text)
	else
		dropdown.Visible = false
	end
end)

-- =============================================================================
-- Input handling
-- =============================================================================
Agent.Initialize(term, function(busy: boolean)
	inputBox.TextEditable = not busy
	inputBox.PlaceholderText = busy and "Working…  (Stop to cancel)"
		or "Message Claude…  ( / for commands · shift+enter for a new line )"
	inputBox.TextColor3 = busy and Theme.TEXT_LO or Theme.TEXT_HI
	stopButton.Visible = busy
	if not busy then refreshStatus() end
end)
Commands.Initialize(term, toggleSettings)

local UserInputService = game:GetService("UserInputService")

local function submit(text: string)
	inputBox.Text = ""
	if text:gsub("%s+", "") == "" then return end
	if not Commands.handle(text) then
		Agent.send(text, OAuth.isLoggedIn)
	end
	refreshStatus()
	inputBox:CaptureFocus()
end

-- Enter sends, Shift+Enter adds a line.
--
-- This watches the text rather than the keyboard, because a focused TextBox
-- swallows its keystrokes: UserInputService.InputBegan does NOT fire for keys
-- that go into a TextBox, so a Return handler there never runs and Enter only
-- ever inserted a newline. A MultiLine box also never reports Enter through
-- FocusLost, so the newline appearing in the text is the only signal there is.
--
-- Growth of exactly one character is what separates a keystroke from a paste —
-- without that check, pasting a snippet containing newlines would fire a send.
local previousText = ""
inputBox:GetPropertyChangedSignal("Text"):Connect(function()
	local text = inputBox.Text
	local grew = #text == #previousText + 1
	previousText = text
	if not grew then return end

	-- The caret sits just after the character that was inserted. Falling back to
	-- a trailing newline covers the case where CursorPosition has not caught up.
	local caret = inputBox.CursorPosition
	local atCaret = caret >= 2 and text:sub(caret - 1, caret - 1) == "\n"
	local atEnd = text:sub(-1) == "\n"
	if not (atCaret or atEnd) then return end

	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
		return   -- Shift+Enter: the newline stays
	end

	-- Enter: cut out the newline it just inserted, send what is left.
	local without = atCaret
		and (text:sub(1, caret - 2) .. text:sub(caret))
		or text:sub(1, -2)
	previousText = ""
	submit(without)
end)

-- Esc cancels: the input keeps focus while streaming, so the keyboard is the
-- closest control to hand. Escape is not text, so it does reach InputBegan.
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if input.KeyCode == Enum.KeyCode.Escape and Agent.isBusy() then
		Agent.stop()
	end
end)

inputBox.FocusLost:Connect(function()
	task.delay(0.1, function() dropdown.Visible = false end)
end)

-- =============================================================================
-- Startup
-- =============================================================================
task.spawn(function()
	local SHA_VECTORS = {
		{ input = "",    expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
		{ input = "abc", expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
	}
	for _, vector in ipairs(SHA_VECTORS) do
		if Sha256.hex(vector.input) ~= vector.expected then
			warn("[Claude Code] SHA-256 self-test FAILED")
			break
		end
	end

	local markdownOk, markdownErr = Markdown.selfTest()
	if not markdownOk then
		warn("[Claude Code] Markdown self-test FAILED: " .. tostring(markdownErr))
	end

	Console.appendLine("Claude Code for Roblox", "system")
	if OAuth.isLoggedIn() then
		Console.appendLine("Logged in. Type /help for commands, or just start typing.", "info")
	else
		Console.appendLine("Not logged in. Type /login to start.", "info")
	end
	Console.appendLine("CWD: " .. term:pwd(), "info")

	-- Warm the API dump so no `cat` pays the fetch. This yields, which is exactly
	-- why it can't happen lazily: the first cat runs inside a stream callback,
	-- and yielding there would stall SSE parsing mid-buffer.
	Props.preload()

	local shellOk, shellErr = Terminal.selfTest()
	if not shellOk then
		warn("[Claude Code] Terminal self-test FAILED: " .. tostring(shellErr))
	end
	local propsOk, propsErr = Props.selfTest()
	if not propsOk then
		warn("[Claude Code] Property lookup self-test FAILED: " .. tostring(propsErr))
	end
end)

print("[Claude Code] Loaded.")
