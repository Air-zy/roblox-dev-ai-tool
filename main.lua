--!strict
-- Claude Code for Roblox — plugin entry point.
--
-- This file does plugin setup and nothing else: widget, toolbar, the input row,
-- and wiring the modules together. Rendering lives in Console, formatting in
-- Markdown, preferences in Settings, the conversation in Agent, slash commands
-- in Commands, and the DataModel browser in Terminal.

assert(plugin ~= nil, "This script must run as a Roblox Studio plugin (the `plugin` global is missing).")

local Sha256   = require(script:WaitForChild("Sha256"))   :: any
local OAuth    = require(script:WaitForChild("OAuth"))    :: any
local Claude   = require(script:WaitForChild("Claude"))   :: any
local Props    = require(script:WaitForChild("Props"))    :: any
local Terminal = require(script:WaitForChild("Terminal")) :: any
local Theme    = require(script:WaitForChild("Theme"))
local Markdown = require(script:WaitForChild("Markdown"))
local Console  = require(script:WaitForChild("Console"))
local Settings = require(script:WaitForChild("Settings"))
local Agent    = require(script:WaitForChild("Agent"))
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
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Bottom,
	true, false,
	900, 320,
	400, 140
)
local widget = plugin:CreateDockWidgetPluginGuiAsync("ClaudeCodeTerminal", widgetInfo)
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
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)
toggleButton:SetActive(widget.Enabled)

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

Console.mount(root, 2)

local inputRow = make("Frame", {
	Name = "InputRow",
	Parent = root,
	BackgroundColor3 = Theme.BG_INPUT,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 32),
	LayoutOrder = 3,
})
make("Frame", {
	Parent = inputRow,
	BackgroundColor3 = Theme.BORDER,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 1),
})
make("TextLabel", {
	Parent = inputRow,
	BackgroundTransparency = 1,
	Size = UDim2.new(0, 24, 1, 0),
	FontFace = Theme.MONO,
	TextSize = 14,
	TextColor3 = Theme.ACCENT,
	TextXAlignment = Enum.TextXAlignment.Center,
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
	Size = UDim2.new(1, -104, 1, 0),
	Position = UDim2.new(0, 24, 0, 0),
	FontFace = Theme.SANS,
	TextSize = Theme.TEXT_SIZE,
	TextColor3 = Theme.TEXT_HI,
	ClearTextOnFocus = false,
	Text = "",
	PlaceholderText = "Message Claude…  ( / for commands )",
	PlaceholderColor3 = Theme.TEXT_LO,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Center,
})

-- =============================================================================
-- Settings popup
-- =============================================================================
-- Settings shouldn't know about OAuth, the Terminal or the Agent, so the entry
-- point supplies the status rows.
local toggleSettings = Settings.mountPanel(widget, function(): { Settings.StatusRow }
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

	table.insert(rows, { label = "Model", value = Settings.model() })
	table.insert(rows, { label = "Thinking", value = Settings.effortName() })
	local searches = Settings.webSearchMaxUses()
	table.insert(rows, { label = "Web search", value = searches > 0 and ("max " .. searches) or "disabled" })
	table.insert(rows, { label = "Run code", value = Settings.allowRun() and "enabled" or "disabled" })
	table.insert(rows, { label = "Working dir", value = term:pwd() })
	table.insert(rows, { label = "Messages", value = tostring(#Agent.conversation()) })
	table.insert(rows, { label = "Status", value = Agent.isBusy() and "streaming" or "idle" })
	return rows
end)
settingsButton.MouseButton1Click:Connect(function() toggleSettings(nil) end)

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
	dropdown.Position = UDim2.new(0, 12, 1, -32 - height - 4)
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
	inputBox.PlaceholderText = busy and "Working…  (Stop to cancel)" or "Message Claude…  ( / for commands )"
	inputBox.TextColor3 = busy and Theme.TEXT_LO or Theme.TEXT_HI
	stopButton.Visible = busy
	if not busy then refreshStatus() end
end)
Commands.Initialize(term, toggleSettings)

-- Esc cancels too: the input keeps focus while streaming, so the keyboard is
-- the closest control to hand.
game:GetService("UserInputService").InputBegan:Connect(function(input: InputObject, processed: boolean)
	if input.KeyCode == Enum.KeyCode.Escape and Agent.isBusy() then
		Agent.stop()
	end
end)

inputBox.FocusLost:Connect(function(enterPressed: boolean)
	task.delay(0.1, function() dropdown.Visible = false end)
	if not enterPressed then return end

	local text = inputBox.Text
	inputBox.Text = ""
	if text:gsub("%s+", "") == "" then return end

	if not Commands.handle(text) then
		Agent.send(text, OAuth.isLoggedIn)
	end
	refreshStatus()
	inputBox:CaptureFocus()
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
