--!strict
-- Plugin entry point.
--
-- This file does plugin setup and nothing else: widget, toolbar, the input row,
-- and wiring the modules together. Rendering lives in Console, formatting in
-- Markdown, preferences in Settings, the conversation in Agent, slash commands
-- in Commands, and the DataModel browser in Terminal.

assert(plugin ~= nil, "This script must run as a Roblox Studio plugin (the `plugin` global is missing).")

-- Every place the product names itself to the user: toolbar, button, window
-- title, startup banner, input placeholder. One string so a rename is one edit
-- rather than a sweep, and so nothing downstream has to know what it says.
--
-- Not the two identifiers below it. `CreateDockWidgetPluginGuiAsync` and
-- `CreateButton` take an ID as their first argument, and Studio keys the saved
-- dock state, size and position to it. Changing an ID does not migrate anything:
-- it orphans the old entry and every existing user's panel reappears at the
-- default floating position. They are invisible, so they buy nothing back.
local NAME = "Agent"

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- Modules are grouped by what they are, not listed flat. A module only ever
-- reaches for a folder it does not live in when it genuinely crosses layers,
-- which is why this is the only file that names all four.
local agent = script:WaitForChild("agent")
local fs     = script:WaitForChild("fs")
local git    = script:WaitForChild("git")
local studio = script:WaitForChild("studio")
local ui    = script:WaitForChild("ui")

local Provider = require(agent:WaitForChild("Provider")) :: any
local Props    = require(studio:WaitForChild("Props"))  :: any
local Fs       = require(fs:WaitForChild("Fs"))         :: any
local Terminal = require(fs:WaitForChild("Terminal"))   :: any
local Git      = require(git:WaitForChild("Git"))       :: any
local Theme    = require(ui:WaitForChild("Theme"))
local Console  = require(ui:WaitForChild("Console"))
local Find     = require(ui:WaitForChild("Find"))
local Settings = require(ui:WaitForChild("Settings"))
local Sessions = require(ui:WaitForChild("Sessions"))
local Agent    = require(agent:WaitForChild("Agent"))
local Commands = require(script:WaitForChild("Commands"))

local make = Theme.make

Provider.Initialize(plugin)
Settings.Initialize(plugin)
Sessions.Initialize(plugin)
-- The remote, the branch and the token. Through the plugin store rather than the
-- DataModel: Team Create replicates the DataModel to every collaborator, and the
-- token must not travel with it.
Git.Initialize(plugin)

local term = Terminal.new(game)
-- Terminal asks this before executing anything, rather than importing Settings
-- itself; keeps the dependency pointing one way.
Terminal.setRunGuard(Settings.allowRun)

-- Widget + toolbar
-- Float, not Bottom: there is no dock state for the centre viewport. Studio
-- only docks to the four edges, so a floating window over the 3D view is as
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
local widget = plugin:CreateDockWidgetPluginGuiAsync(NAME .. "TerminalFloat", widgetInfo)
widget.Title = NAME
-- DockWidgetPluginGui defaults to ZIndexBehavior.Global, where ZIndex is compared
-- across the entire GUI rather than among siblings. Under Global, a child that
-- doesn't set ZIndex sits at 1 and renders BEHIND any ancestor with a higher
-- value: which is why the settings card hid its own contents. Sibling makes
-- layering follow the hierarchy, so a child always draws above its parent and no
-- widget has to hand-pick a number.
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local toolbar = plugin:CreateToolbar(NAME)
local toggleButton = toolbar:CreateButton("CodeToggle", NAME, "")
toggleButton.Click:Connect(function()
	if RunService:IsRunning() then return end
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)
toggleButton:SetActive(widget.Enabled)

-- Edit-mode only. The plugin keeps running through a playtest, that is why the
-- widget used to sit over the game, so the run state has to be watched, not
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

-- Chrome
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
local findButton = make("TextButton", {
	Name = "FindButton",
	Parent = headerBar,
	BackgroundTransparency = 1,
	Size = UDim2.new(0, 28, 1, 0),
	Position = UDim2.new(0, 32, 0, 0),
	FontFace = Theme.ICON,
	TextSize = 15,
	TextColor3 = Theme.TEXT_MED,
	Text = "magnifying-glass",
	AutoButtonColor = false,
})
-- No title label here: the widget's own title bar already carries NAME, and a
-- second copy inside it only costs header width.
-- Nothing else lives in this bar. The model/effort readout moved to a chip in
-- the input row that also SETS the model, and the gear moved to the bottom of
-- the sessions drawer, a status line you cannot act on is not worth a corner.
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
-- that corner and the chip slides left of it rather than disappearing, which
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
	-- Off deliberately, and it is what makes Shift+Enter possible at all. With
	-- MultiLine on, the box swallows Enter to insert its own newline and never
	-- reports the key: FocusLost doesn't fire, no InputBegan anywhere in the
	-- widget fires either (measured, see the FocusLost handler), so Enter and
	-- Shift+Enter arrive byte-identical and there is nothing left to tell them
	-- apart. Off, Enter comes back as an event carrying its modifiers, and the
	-- newline is inserted by hand there instead.
	MultiLine = false,
	ClearTextOnFocus = false,
	Text = "",
	PlaceholderText = "Message " .. NAME .. "…  ( / commands · shift+enter newline · shift+esc find )",
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
-- the output frame's size on every keystroke, and because that frame is a
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

-- Settings popup
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
local usageWindows: { any }? = nil
local usageError: string? = nil
local usageFetchedAt = 0
local usageInFlight = false

-- Already formatted by whichever provider fetched them: one reports rolling
-- utilisation windows and the other reports credits, and this panel is not the
-- place to know the difference.
local function usageRows(rows: { Settings.StatusRow })
	if not Provider.auth.isLoggedIn() then return end
	if not usageWindows then
		table.insert(rows, { label = "Plan usage", value = usageError or "loading…" })
		return
	end
	local age = usageError and " · stale" or ""
	for _, row in ipairs(usageWindows) do
		table.insert(rows, {
			label = row.label,
			value = row.value .. age,
			bar = row.bar,
		})
	end
end

local toggleSettings, refreshSettings = Settings.mountPanel(widget, function(): { Settings.StatusRow }
	local rows: { Settings.StatusRow } = {}

	if Provider.auth.isLoggedIn() then
		local expiry = Provider.auth.tokenExpiry()
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
	-- already carries model . effort.
	table.insert(rows, { label = "Working dir", value = term:pwd() })
	table.insert(rows, { label = "Messages", value = tostring(#Agent.conversation()) })
	local usage = Agent.usage()
	table.insert(rows, {
		label = "Tokens",
		value = string.format("%s in · %s out", compact(usage.input), compact(usage.output)),
	})
	-- Cache hit rate over the session. Its own row rather than a third figure on
	-- the one above, which truncates at the end and would drop it. Absent before
	-- the first turn, where 0 of 0 is not 0%.
	if usage.input > 0 then
		table.insert(rows, {
			label = "Cache hits",
			value = string.format("%d%% · %s read", math.floor(usage.cached / usage.input * 100),
				compact(usage.cached)),
		})
	end
	return rows
end)

-- The bars come from a network call, so they can't be produced inside the
-- synchronous status provider above. Fetch on open, redraw when it lands.
local USAGE_MAX_AGE = 60
local function refreshUsage()
	if usageInFlight or not Provider.auth.isLoggedIn() then return end
	if usageWindows and os.clock() - usageFetchedAt < USAGE_MAX_AGE then return end
	usageInFlight = true
	task.spawn(function()
		local windows, err = Provider.auth.fetchUsage()
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

-- Sessions drawer
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

-- Find in conversation
-- Parented to the widget, not to root, so it floats over the console instead of
-- pushing it down, and so the sessions drawer shifting root leaves it alone.
local toggleFind = Find.mount(widget, Agent.conversation, Sessions.reveal, function()
	return inputRow.AbsoluteSize.Y + 4
end)
findButton.MouseButton1Click:Connect(function() toggleFind(nil) end)

-- The only keyboard route Studio dispatches ahead of a focused text box, and the
-- documented way a plugin gets a shortcut at all. It cannot ship with a chord:
-- File > Advanced > Customize Shortcuts, bind whatever you like to it.
--
-- There is deliberately no Ctrl+F here. Nothing in the plugin API can see it:
-- UserInputService.InputBegan is documented to fire "only when the Roblox client
-- window is in focus", which is the 3D view and never this widget;
-- ContextActionService is client-LocalScript only; and GuiObject.InputBegan, the
-- one event that does reach a PluginGui's children, loses to a focused TextBox —
-- which in this panel is nearly always one, since submit recaptures the input box
-- and every console line is editable so it can be selected and copied. Three
-- rounds of trying is enough. Shift+Esc is the shortcut that works, and it works
-- because Esc is the one key a focused TextBox hands back; see the FocusLost
-- handler further down.
local findAction = plugin:CreatePluginAction(
	"AgentFindInChat", "Find in chat",
	"Search this conversation, thinking and tool output included", "", true)
findAction.Triggered:Connect(function() toggleFind(true) end)

-- Model picker
-- The same list the settings panel offers, in a popup over the input row, so
-- switching model is one click from where you type instead of three from a
-- panel. Both write the same setting; neither is the source of truth.
--
-- The registry's `label` is written for a settings row several times wider than
-- anything here, and at this width it truncates mid-parenthetical. The compact
-- rows read `name` and `hint` instead, which the registry carries as separate
-- fields. This file used to recover them from the label with two regexes, one of
-- which stripped the vendor word by name — a thing Provider.luau says nothing
-- outside providers/ may do, and a guess that breaks on a two-word vendor.

local function refreshModel()
	local id = Settings.model()
	local effort = string.format(
		'  <font color="#6B6862" size="12">%s</font>',
		Settings.effortName():lower()
	)
	for _, entry in ipairs(Provider.wire.MODELS) do
		if entry.id == id then
			modelButton.Text = entry.name .. effort
			return
		end
	end
	-- A model set by `/model claude-something` that is not in the list.
	modelButton.Text = id .. effort
end

-- Effort hangs off this menu rather than getting its own control, which is where
-- Claude Code puts it too, there it is a slider you nudge with left/right while
-- a model row is highlighted, plus a separate /effort command. A slider is a
-- keyboard shape; with a mouse the same idea is a submenu, so the Effort row
-- swaps this popup to a second page and back.
--
-- A ScrollingFrame rather than a Frame, and the reason is the model list. This
-- used to be three hardcoded entries and grew to fit them; OpenRouter's free
-- roster is around twenty and is FETCHED, so its length is not something this
-- file can know. AutomaticSize grows the popup to its content, MaxSize stops it
-- growing off the top of the widget, and AutomaticCanvasSize gives it something
-- to scroll once it hits that cap.
--
-- No "More models" page, which Claude Code does have. Scrolling covers it, and
-- `/model <anything>` still takes an id no list has ever heard of.
local modelPopup = make("ScrollingFrame", {
	Name = "ModelPopup",
	Parent = widget,
	BackgroundColor3 = Theme.BG_INPUT,
	BorderColor3 = Theme.BORDER,
	BorderSizePixel = 1,
	AnchorPoint = Vector2.new(1, 1),
	-- Height follows the page, which is now three different lengths.
	Size = UDim2.new(0, 240, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ScrollingDirection = Enum.ScrollingDirection.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = Theme.BORDER,
	Visible = false,
	ZIndex = 45,
})
-- Insurance rather than the mechanism: the models page shows at most
-- MAX_MODEL_ROWS entries, so this only ever binds on the effort page.
make("UISizeConstraint", { Parent = modelPopup, MaxSize = Vector2.new(240, 320) })

-- At most this many models on screen at once. OpenRouter's free roster is about
-- twenty and every one of them has a long slug, so the list was taller than the
-- widget and ran off the top of it. Four plus a search box is the whole list
-- reachable in a couple of keystrokes, and a fixed popup height.
local MAX_MODEL_ROWS = 4

-- Built ONCE and never destroyed, which is the entire trick: drawPopup runs on
-- every keystroke, and a TextBox that gets rebuilt underneath the person typing
-- loses focus after the first character. Sessions' drawer filter is built the
-- same way and for the same reason. Hidden on the pages that are not the model
-- list; UIListLayout skips invisible children, so it costs no space there.
local modelQuery = ""
local modelSearch: TextBox
do
	local row = make("Frame", {
		Name = "ModelSearch",
		Parent = modelPopup,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		LayoutOrder = 0,
		ZIndex = 46,
	})
	make("TextLabel", {
		Parent = row,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 16, 1, 0),
		Position = UDim2.new(0, 9, 0, 0),
		FontFace = Theme.ICON,
		TextSize = 12,
		TextColor3 = Theme.TEXT_LO,
		Text = "magnifying-glass",
		ZIndex = 47,
	})
	modelSearch = make("TextBox", {
		Parent = row,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -34, 1, 0),
		Position = UDim2.new(0, 28, 0, 0),
		FontFace = Theme.SANS,
		TextSize = 12,
		TextColor3 = Theme.TEXT_HI,
		ClearTextOnFocus = false,
		MultiLine = false,
		Text = "",
		PlaceholderText = "Search models…",
		PlaceholderColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 47,
	}) :: TextBox
end
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

local function popupNote(order: number, text: string)
	make("TextLabel", {
		Parent = modelPopup,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -20, 0, 22),
		Position = UDim2.new(0, 10, 0, 0),
		FontFace = Theme.SANS,
		TextSize = 12,
		TextColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = text,
		LayoutOrder = order,
		ZIndex = 46,
	})
end

local function popupDivider(order: number)
	make("Frame", {
		Parent = modelPopup,
		BackgroundColor3 = Theme.BORDER,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
		LayoutOrder = order,
		ZIndex = 46,
	})
end

-- Rebuilt on every open and every page flip, rather than kept in sync: /model,
-- /effort, /provider and the settings panel can all have moved the selection
-- since the last time this was on screen.
local effortPage = false
local providerPage = false
local function drawPopup()
	for _, child in ipairs(modelPopup:GetChildren()) do
		if child:IsA("GuiObject") and child ~= modelSearch.Parent then child:Destroy() end
	end
	-- Only the model list is searchable; the other two pages are five rows and
	-- two rows respectively.
	modelSearch.Parent.Visible = not (effortPage or providerPage)

	if providerPage then
		popupRow(1, "Models", "chevron-small-left", nil, false, function()
			providerPage = false
			drawPopup()
		end)
		popupDivider(2)
		for i, entry in ipairs(Provider.list()) do
			popupRow(i + 2, entry.label, entry.id == Provider.id and "check-small" or nil,
				entry.hint, false, function()
					if entry.id ~= Provider.id then
						Provider.use(entry.id)
						Settings.reloadModel()
						-- The conversation is shaped by whoever produced it, so it
						-- cannot come along. A NEW session rather than a wipe: the old
						-- one stays on disk and reopens when you switch back.
						Sessions.new()
						Console.appendLine(string.format("Provider: %s · model %s",
							Provider.label(entry.id), Settings.model()), "assistant")
						if not Provider.auth.isLoggedIn() then
							Console.appendLine("Not logged in for this provider. Use /login.", "info")
						end
					end
					providerPage = false
					modelPopup.Visible = false
					refreshModel()
				end)
		end
		return
	end

	if effortPage then
		popupRow(1, "Models", "chevron-small-left", nil, false, function()
			effortPage = false
			drawPopup()
		end)
		popupDivider(2)
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
	-- Matched against the id as well as the name, because the id is what carries
	-- the vendor: "ox" should find stealth/ox-alpha, and so should "stealth".
	local shown, matches = 0, 0
	for _, entry in ipairs(Provider.wire.MODELS) do
		local hit = modelQuery == ""
			or entry.name:lower():find(modelQuery, 1, true) ~= nil
			or entry.id:lower():find(modelQuery, 1, true) ~= nil
		if hit then
			matches += 1
			if shown < MAX_MODEL_ROWS then
				shown += 1
				-- The parenthetical rides in the trailing column rather than being
				-- dropped: it is the only thing separating "Max only" from "fastest"
				-- at the moment of choosing.
				local id, name, hint = entry.id, entry.name, entry.hint
				popupRow(shown, name, id == current and "check-small" or nil, hint, false, function()
					Settings.setModel(id)
					modelPopup.Visible = false
					refreshModel()
				end)
			end
		end
	end

	local n = shown
	if matches == 0 then
		n += 1
		popupNote(n, "Nothing matches that.")
	elseif matches > shown then
		-- Said rather than silently truncated: the selected model can easily be
		-- one of the ones not drawn, and without this the list looks complete.
		n += 1
		popupNote(n, string.format("%d more — keep typing", matches - shown))
	end

	popupDivider(n + 1)
	popupRow(n + 2, "Provider", nil, Provider.label():lower(), true, function()
		providerPage = true
		drawPopup()
	end)
	popupRow(n + 3, "Effort", nil, Settings.effortName():lower(), true, function()
		effortPage = true
		drawPopup()
	end)
end

modelSearch:GetPropertyChangedSignal("Text"):Connect(function()
	modelQuery = modelSearch.Text:lower()
	drawPopup()
end)

modelButton.MouseButton1Click:Connect(function()
	if modelPopup.Visible then
		modelPopup.Visible = false
		return
	end
	effortPage = false
	providerPage = false
	-- Every open starts from the whole list. Setting Text fires the handler
	-- above, which redraws, so `drawPopup` below is for the case where it was
	-- already empty and nothing changed.
	modelSearch.Text = ""
	modelQuery = ""
	drawPopup()
	-- Right-aligned with the chip, floating just above the input row however tall
	-- that row currently is.
	modelPopup.Position = UDim2.new(1, -8, 1, -inputRow.AbsoluteSize.Y - 4)
	modelPopup.Visible = true
end)
refreshModel()

-- Autocomplete dropdown
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
	-- Sits above the input row, whatever height the row currently is, it grows
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

-- Input handling
-- The spinner runs at the bottom of the console, not in the input. It used to
-- take over the placeholder with TextEditable off, which meant a turn you were
-- waiting on also cost you the ability to type the next one. The box stays
-- editable and keeps its own text; only SENDING is blocked while busy, see the
-- Enter handler.
--
-- The idle edge is one of the two places the session is written to disk: it
-- fires on a finished turn, an error and a Stop alike. The other is the
-- checkpoint passed alongside it, which Agent fires as a message is sent and
-- after each batch of tool results — the edge alone meant a run of forty tool
-- calls was a single busy period, and a Studio crash inside it cost the lot.
Agent.Initialize(term, function(busy: boolean)
	Console.setWorking(busy)
	stopButton.Visible = busy
	modelButton.Position = UDim2.new(1, busy and CHIP_X_BUSY or CHIP_X_IDLE, 0.5, 0)
	inputBox.Size = UDim2.new(1, busy and -264 or -196, 0, 32)
	if not busy then
		refreshModel()
		Sessions.save()
	end
end, Sessions.save)

-- Shell mode: the input row talks to the terminal instead of to Claude.
--
-- This is what a shell panel would have been, minus the panel. The console is
-- already a scrollback, the input row is already a line editor, and `cmd` lines
-- already render with a `$` in the accent colour, so a second window would have
-- been a second copy of all three. What was actually missing is that every line
-- needed a `/sh ` in front of it and there was nowhere to see the cwd.
--
-- The cwd lives in the PLACEHOLDER rather than in front of each echoed line: it
-- is one place, always current, and it costs nothing per line of output.
local shellMode = false
local IDLE_PLACEHOLDER = inputBox.PlaceholderText

-- Read fresh every time, because `cd` moves it and a cached prompt is a wrong
-- one. One function rather than the string twice: entering the shell and running
-- a line both need it, and the two would drift.
local function shellPrompt(): string
	return term:pwd() .. "  ( exit or /sh leaves · " .. #Terminal.COMMANDS .. " commands )"
end

local function setShellMode(on: boolean?)
	shellMode = if on == nil then not shellMode else on
	inputBox.PlaceholderText = if shellMode then shellPrompt() else IDLE_PLACEHOLDER
	Console.appendLine(if shellMode
		then "shell — every line goes to the terminal until `exit`"
		else "shell closed", "system")
	inputBox:CaptureFocus()
end

Commands.Initialize(term, toggleSettings, toggleFind, setShellMode)

local function submit(text: string)
	inputBox.Text = ""
	if text:gsub("%s+", "") == "" then return end
	-- Typing is the moment you are done reading someone else's session: put the
	-- live one back on screen before anything is appended to it. A no-op unless a
	-- peek is up.
	Sessions.endPeek()
	-- Slash commands still work in the shell — /clear and /model are not things
	-- to have to leave for — so this only claims the lines that are not one.
	if shellMode and text:sub(1, 1) ~= "/" then
		if text == "exit" then
			setShellMode(false)
			return
		end
		-- The `$` and the colour come from Console's `cmd` kind, which is what
		-- Commands.handle already prints slash lines with.
		Console.appendLine(text, "cmd")
		Commands.runShell(text)
		-- `cd` moves it, so the prompt is rebuilt rather than left as it was.
		inputBox.PlaceholderText = shellPrompt()
		inputBox:CaptureFocus()
		return
	end
	if not Commands.handle(text) then
		Agent.send(text, Provider.auth.isLoggedIn)
	end
	-- `/model` changes it from under the chip.
	refreshModel()
	inputBox:CaptureFocus()
end

-- Enter sends, Shift+Enter adds a line.
--
-- FocusLost is the only keyboard signal a plugin widget actually delivers, and
-- it only delivers it because MultiLine is off. Everything else was measured
-- dead while the box holds focus: UserInputService (which the Studio widget docs
-- say outright expects the game window), GuiObject.InputBegan on the box, on
-- `root`, and on a transparent catcher frame across the whole widget, and
-- IsKeyDown along with them. Not one key event, ever, so Shift can only be read
-- off the InputObject that FocusLost hands back, at the instant it hands it back.
--
-- CursorPosition reads -1 as soon as focus goes, and FocusLost is exactly that
-- moment, so the last live caret is what the newline gets inserted at.
local caretAt = 1
inputBox:GetPropertyChangedSignal("CursorPosition"):Connect(function()
	if inputBox.CursorPosition > 0 then caretAt = inputBox.CursorPosition end
end)

inputBox.FocusLost:Connect(function(enterPressed: boolean, cause: InputObject?)
	-- Esc gives up focus and hands over the key that did it, which is the only
	-- way ANY key reaches this plugin while you are typing — and the modifiers
	-- come with it, exactly as they do for the Shift+Enter branch below. That
	-- makes a modified Esc the one keyboard shortcut that can work from inside
	-- the message box, so Shift+Esc is what opens the find panel. Nothing else
	-- can; see the PluginAction comment above for what was tried.
	--
	-- Shift and not Ctrl: Ctrl+Esc is the Windows Start menu.
	if cause and cause.KeyCode == Enum.KeyCode.Escape then
		if cause:IsModifierKeyDown(Enum.ModifierKey.Shift) then
			toggleFind(true)
		elseif Agent.isBusy() then
			Agent.stop()
		end
		return
	end
	if not enterPressed then return end

	if cause ~= nil and cause:IsModifierKeyDown(Enum.ModifierKey.Shift) then
		local text = inputBox.Text
		local index = math.clamp(caretAt, 1, #text + 1)
		-- A single-line box has nowhere to put the Return, so it leaves a space at
		-- the caret instead. Left alone it becomes the first character of the new
		-- line: the space this used to prepend. The caret was read before that
		-- happened, so it is sitting right at `index`.
		local tail = text:sub(index)
		if tail:sub(1, 1) == " " then tail = tail:sub(2) end
		inputBox.Text = text:sub(1, index - 1) .. "\n" .. tail
		inputBox:CaptureFocus()
		-- After CaptureFocus, not before: focusing moves the caret itself.
		task.defer(function() inputBox.CursorPosition = index + 1 end)
	elseif Agent.isBusy() and not shellMode then
		-- The draft stays put and nothing is sent; typing carries on.
		--
		-- Shell mode is exempt: the line goes to the terminal and never near the
		-- turn that is streaming, and being able to `ls` while it works is most of
		-- the reason to be in the shell at all. Nothing reaches Claude from here
		-- either way — submit routes every non-slash line to the terminal while
		-- the mode is on, and a slash line was never Claude's to begin with.
		inputBox:CaptureFocus()
	else
		-- Same space, at the end this time.
		submit((inputBox.Text:gsub("%s+$", "")))
	end
end)

-- Esc from the viewport, the one place UserInputService does report input: its
-- docs say it fires only while the client window has focus, which is precisely
-- the 3D view and never this widget. Nothing else is hung off it: a key pressed
-- while working in the viewport is meant for Studio, not for us.
UserInputService.InputBegan:Connect(function(input: InputObject)
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

-- Startup
--
-- The self-tests used to run here, all of them, on the frame the widget opens:
-- about 1800 lines of test code, thirty-odd Instances built and torn down, and
-- half a dozen plugin-setting writes, before anything was on screen. That was
-- the startup cost, and it re-proved on every open what had not changed since
-- the last open. They live behind `/selftest` now — the same set, none of it
-- trimmed, run when something has actually been edited.
--
-- What stays here is the two things that are not tests: the API dump has to be
-- warm before the first `cat`, and the mtime journal only knows about what
-- happened after it started watching.
task.spawn(function()
	Console.appendLine(NAME, "system")
	if Provider.auth.isLoggedIn() then
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

	-- Start observing modification times. Nothing before this point has one, so
	-- the earlier this runs the more of the session `ls -t` can answer for.
	Fs.watch()
end)

print("[agent] Loaded.")
