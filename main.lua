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
local Sessions = require(ui:WaitForChild("Sessions"))
local Agent    = require(agent:WaitForChild("Agent"))
local Commands = require(script:WaitForChild("Commands"))

local make = Theme.make

OAuth.Initialize(plugin)
Claude.Initialize(OAuth)
Settings.Initialize(plugin)
Sessions.Initialize(plugin)

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
local sessionsButton = make("TextButton", {
	Name = "SessionsButton",
	Parent = headerBar,
	BackgroundTransparency = 1,
	Size = UDim2.new(0, 28, 1, 0),
	Position = UDim2.new(0, 4, 0, 0),
	FontFace = Theme.ICON,
	TextSize = 18,
	TextColor3 = Theme.TEXT_MED,
	Text = "three-bars-horizontal",
	AutoButtonColor = false,
})
-- No title label here: the widget's own title bar already says "Claude Code",
-- and a second copy inside it only costs header width.
-- Nothing else lives in this bar. The model/effort readout moved to a chip in
-- the input row that also SETS the model, and the gear moved to the bottom of
-- the sessions drawer — a status line you cannot act on is not worth a corner.
-- No rule under the bar either: the header is empty enough that a divider only
-- draws a line across nothing.

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

-- The model chip sits at the right of the input row; while streaming, Stop takes
-- that corner and the chip slides left of it rather than disappearing — which
-- model is answering is exactly what you want to read mid-turn. Replaces the old
-- header status line, which spent a quarter of the header saying something
-- nothing could act on.
local CHIP_X_IDLE = -8
local CHIP_X_BUSY = -76 -- clears the 62px Stop button plus a 6px gap
local modelButton = make("TextButton", {
	Name = "ModelButton",
	Parent = inputRow,
	BackgroundColor3 = Theme.BG_DARK,
	-- Invisible until you go for it: at rest this is a label saying which model
	-- is answering, and a filled pill would read as the loudest thing in a row
	-- whose actual job is the text you are typing.
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, CHIP_X_IDLE, 0.5, 0),
	Size = UDim2.new(0, 160, 0, 22),
	FontFace = Theme.SANS,
	TextSize = 13,
	TextColor3 = Theme.TEXT_HI,
	TextXAlignment = Enum.TextXAlignment.Left,
	-- The effort rides along in a dimmer, smaller span after the model name.
	RichText = true,
	Text = "",
	AutoButtonColor = false,
})
make("UICorner", { Parent = modelButton, CornerRadius = UDim.new(0, 4) })
make("UIPadding", { Parent = modelButton, PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 20) })
make("TextLabel", {
	Parent = modelButton,
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 14, 0, 0),
	Size = UDim2.new(0, 14, 1, 0),
	FontFace = Theme.ICON,
	TextSize = 12,
	TextColor3 = Theme.TEXT_LO,
	Text = "chevron-small-down",
})
-- AutoButtonColor is off across this UI (it tints by transparency, which does
-- nothing to a transparent background), so hover is done by hand.
modelButton.MouseEnter:Connect(function()
	modelButton.BackgroundTransparency = 0
end)
modelButton.MouseLeave:Connect(function()
	modelButton.BackgroundTransparency = 1
end)

local inputBox = make("TextBox", {
	Name = "Input",
	Parent = inputRow,
	BackgroundTransparency = 1,
	-- Leaves room for the model chip; the busy callback widens the gap again for
	-- the Stop button that appears beside it while streaming.
	Size = UDim2.new(1, -196, 0, 32),
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

-- =============================================================================
-- Sessions drawer
-- =============================================================================
-- A drawer, not a popup: it stays until the same button closes it, and the
-- console is moved over rather than covered. Sessions owns the panel; the shift
-- is the entry point's business, since it is the only thing that knows how the
-- widget is laid out.
--
-- The autocomplete list is positioned against the widget rather than the console
-- (it has to escape the input row's bounds), so it does not ride along with the
-- shift and needs the same offset applied by hand.
local sidebarOffset = 0
local toggleSessions = Sessions.mountSidebar(widget, function()
	refreshUsage()
	toggleSettings(nil)
end)
sessionsButton.MouseButton1Click:Connect(function()
	sidebarOffset = if toggleSessions(nil) then Sessions.WIDTH else 0
	root.Position = UDim2.new(0, sidebarOffset, 0, 0)
	root.Size = UDim2.new(1, -sidebarOffset, 1, 0)
end)

-- =============================================================================
-- Model picker
-- =============================================================================
-- The same list the settings panel offers, in a popup over the input row, so
-- switching model is one click from where you type instead of three from a
-- panel. Both write the same setting; neither is the source of truth.
--
-- The registry labels ("Claude Sonnet 5 (recommended)") are written for a
-- settings row several times wider than anything here, and at this width they
-- truncate to "Claude Sonnet 5 (recomm…". Split them instead: the name loses the
-- "Claude " every entry shares, and the parenthetical becomes the dim value on
-- the right, where the row already has a column for it.
local function splitModel(label: string): (string, string?)
	local name = (label:gsub("^Claude ", ""))
	local hint = name:match("%((.-)%)$")
	if hint then
		name = (name:gsub("%s*%b()$", ""))
	end
	return name, hint
end

local function shortModel(label: string): string
	local name = splitModel(label)
	return name
end

local function refreshModel()
	local id = Settings.model()
	local effort = string.format(
		'  <font color="#6B6862" size="12">%s</font>',
		Settings.effortName():lower()
	)
	for _, entry in ipairs(Claude.MODELS) do
		if entry.id == id then
			modelButton.Text = shortModel(entry.label) .. effort
			return
		end
	end
	-- A model set by `/model claude-something` that is not in the list.
	modelButton.Text = id .. effort
end

-- Effort hangs off this menu rather than getting its own control, which is where
-- Claude Code puts it too — there it is a slider you nudge with left/right while
-- a model row is highlighted, plus a separate /effort command. A slider is a
-- keyboard shape; with a mouse the same idea is a submenu, so the Effort row
-- swaps this popup to a second page and back.
--
-- No "More models" page, which Claude Code does have: it is there because that
-- list runs to a dozen entries including legacy ones. Ours is three, and
-- `/model claude-anything` already takes an id the list has never heard of.
local modelPopup = make("Frame", {
	Name = "ModelPopup",
	Parent = widget,
	BackgroundColor3 = Theme.BG_INPUT,
	BorderColor3 = Theme.BORDER,
	BorderSizePixel = 1,
	AnchorPoint = Vector2.new(1, 1),
	-- Height follows the page, which is two different lengths.
	Size = UDim2.new(0, 240, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Visible = false,
	ZIndex = 45,
})
make("UIListLayout", { Parent = modelPopup, SortOrder = Enum.SortOrder.LayoutOrder })
make("UIPadding", { Parent = modelPopup, PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2) })

-- marker is a Builder Icons name drawn in the left column: a check for the
-- current selection, a back chevron for the row that returns to the models.
-- `trailing` is the dim value on the right, `chevron` the "opens a page" hint.
local function popupRow(
	order: number,
	label: string,
	marker: string?,
	trailing: string?,
	chevron: boolean,
	onClick: () -> ()
)
	local selected = marker == "check-small"
	local row = make("TextButton", {
		Parent = modelPopup,
		BackgroundColor3 = Theme.BG_DARK,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 28),
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		ZIndex = 46,
	})
	row.MouseEnter:Connect(function() row.BackgroundTransparency = 0 end)
	row.MouseLeave:Connect(function() row.BackgroundTransparency = 1 end)
	if marker then
		make("TextLabel", {
			Parent = row,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 16, 1, 0),
			Position = UDim2.new(0, 8, 0, 0),
			FontFace = Theme.ICON,
			TextSize = 14,
			-- The back chevron is navigation, not a selection: only the check earns
			-- the accent.
			TextColor3 = selected and Theme.ACCENT or Theme.TEXT_MED,
			Text = marker,
		})
	end
	make("TextLabel", {
		Parent = row,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -132, 1, 0),
		Position = UDim2.new(0, 28, 0, 0),
		FontFace = Theme.SANS,
		TextSize = 14,
		TextColor3 = selected and Theme.ACCENT or Theme.TEXT_HI,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = label,
	})
	if trailing then
		make("TextLabel", {
			Parent = row,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, chevron and -22 or -10, 0, 0),
			Size = UDim2.new(0, 96, 1, 0),
			FontFace = Theme.SANS,
			TextSize = 13,
			TextColor3 = Theme.TEXT_MED,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = trailing,
		})
	end
	if chevron then
		make("TextLabel", {
			Parent = row,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 0),
			Size = UDim2.new(0, 14, 1, 0),
			FontFace = Theme.ICON,
			TextSize = 14,
			TextColor3 = Theme.TEXT_MED,
			Text = "chevron-small-right",
		})
	end
	row.MouseButton1Click:Connect(onClick)
end

-- Rebuilt on every open and every page flip, rather than kept in sync: it is
-- eight rows, and /model, /effort and the settings panel can all have moved the
-- selection since the last time this was on screen.
local effortPage = false
local function drawPopup()
	for _, child in ipairs(modelPopup:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end

	if effortPage then
		popupRow(1, "Models", "chevron-small-left", nil, false, function()
			effortPage = false
			drawPopup()
		end)
		make("Frame", {
			Parent = modelPopup,
			BackgroundColor3 = Theme.BORDER,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 1),
			LayoutOrder = 2,
			ZIndex = 46,
		})
		local current = Settings.effortName()
		for i, level in ipairs(Settings.EFFORT_LEVELS) do
			popupRow(i + 2, level.name, level.name == current and "check-small" or nil,
				level.hint, false, function()
					Settings.setEffort(i)
					refreshModel()
					-- Stays open: effort is the setting you are most likely to try a
					-- couple of values of before sending.
					drawPopup()
				end)
		end
		return
	end

	local current = Settings.model()
	for i, entry in ipairs(Claude.MODELS) do
		-- The parenthetical rides in the trailing column rather than being dropped:
		-- it is the only thing separating "Max only" from "fastest" at the moment
		-- of choosing.
		local name, hint = splitModel(entry.label)
		popupRow(i, name, entry.id == current and "check-small" or nil, hint, false, function()
			Settings.setModel(entry.id)
			modelPopup.Visible = false
			refreshModel()
		end)
	end
	make("Frame", {
		Parent = modelPopup,
		BackgroundColor3 = Theme.BORDER,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
		LayoutOrder = #Claude.MODELS + 1,
		ZIndex = 46,
	})
	popupRow(#Claude.MODELS + 2, "Effort", nil, Settings.effortName():lower(), true, function()
		effortPage = true
		drawPopup()
	end)
end

modelButton.MouseButton1Click:Connect(function()
	if modelPopup.Visible then
		modelPopup.Visible = false
		return
	end
	effortPage = false
	drawPopup()
	-- Right-aligned with the chip, floating just above the input row however tall
	-- that row currently is.
	modelPopup.Position = UDim2.new(1, -8, 1, -inputRow.AbsoluteSize.Y - 4)
	modelPopup.Visible = true
end)
refreshModel()

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
	-- The offset keeps it over the console instead of over an open drawer.
	dropdown.Position = UDim2.new(0, 12 + sidebarOffset, 1, -inputRow.AbsoluteSize.Y - height - 4)
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
-- The spinner runs at the bottom of the console, not in the input. It used to
-- take over the placeholder with TextEditable off, which meant a turn you were
-- waiting on also cost you the ability to type the next one. The box stays
-- editable and keeps its own text; only SENDING is blocked while busy — see the
-- Enter handler.
--
-- The idle edge is also where the session is written to disk: it fires on a
-- finished turn, an error and a Stop alike, so a crash only ever costs the turn
-- that was in flight.
Agent.Initialize(term, function(busy: boolean)
	Console.setWorking(busy)
	stopButton.Visible = busy
	modelButton.Position = UDim2.new(1, busy and CHIP_X_BUSY or CHIP_X_IDLE, 0.5, 0)
	inputBox.Size = UDim2.new(1, busy and -264 or -196, 0, 32)
	if not busy then
		refreshModel()
		Sessions.save()
	end
end)
Commands.Initialize(term, toggleSettings)

local UserInputService = game:GetService("UserInputService")

local function submit(text: string)
	inputBox.Text = ""
	if text:gsub("%s+", "") == "" then return end
	if not Commands.handle(text) then
		Agent.send(text, OAuth.isLoggedIn)
	end
	-- `/model` changes it from under the chip.
	refreshModel()
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

	-- Busy: the draft stays put and nothing is sent. Only the newline goes, so
	-- holding Enter while waiting doesn't pad the message with blank lines.
	-- Assigning .Text re-enters this handler, which is harmless — the text shrank,
	-- so `grew` is false and it returns after resyncing previousText.
	if Agent.isBusy() then
		previousText = without
		inputBox.Text = without
		inputBox.CursorPosition = if atCaret then caret - 1 else #without + 1
		return
	end

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

-- Going back to typing dismisses the picker; nothing else needs to catch clicks
-- for it.
inputBox.Focused:Connect(function()
	modelPopup.Visible = false
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

	-- Straight back into the last conversation for this place, which is the whole
	-- point of saving them: a Studio crash should cost nothing but the turn that
	-- was running. Silent when there is nothing to restore.
	Sessions.restoreLast()

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
	local agentOk, agentErr = Agent.selfTest()
	if not agentOk then
		warn("[Claude Code] Context trimming self-test FAILED: " .. tostring(agentErr))
	end
	local cacheOk, cacheErr = Claude.selfTest()
	if not cacheOk then
		warn("[Claude Code] Prompt cache self-test FAILED: " .. tostring(cacheErr))
	end
	local sessionsOk, sessionsErr = Sessions.selfTest()
	if not sessionsOk then
		warn("[Claude Code] Session storage self-test FAILED: " .. tostring(sessionsErr))
	end
end)

print("[Claude Code] Loaded.")
