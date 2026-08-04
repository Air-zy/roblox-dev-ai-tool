--!strict
-- Settings.luau — persisted preferences, shown in a floating popup.
--
-- State lives in plugin:SetSetting, so it survives Studio restarts.
--
-- EFFORT is a real, first-class Anthropic parameter: output_config.effort, with
-- levels low | medium | high | xhigh | max. It governs total token spend for the
-- whole response — prose, tool calls, and thinking alike — and needs no beta
-- header on current models. "high" is the API default.
--
-- thinkingBudget below exists only for models that predate adaptive thinking
-- (Haiku 4.5 here). On those, effort is unsupported and budget_tokens is the
-- only lever; on Claude 5 models budget_tokens is rejected outright. Claude.luau
-- picks the right one per model.

local Theme = require(script.Parent:WaitForChild("Theme"))
-- Reaches into agent/ for the model list only. Settings is the one module that
-- is genuinely half UI and half configuration; if it ever splits, the prefs half
-- is what belongs next to the agent.
local Claude = require(script.Parent.Parent:WaitForChild("agent"):WaitForChild("Claude"))

local make = Theme.make

local Settings = {}

local KEY_MODEL  = "cc_model"
local KEY_EFFORT = "cc_effort"
local KEY_SYSTEM = "cc_system"
local KEY_RUN    = "cc_allow_run"
local KEY_SEARCH = "cc_web_search"

local DEFAULT_SYSTEM = ""
Settings.DEFAULT_SYSTEM = DEFAULT_SYSTEM

-- maxTokens is a hard ceiling on thinking PLUS answer, so it has to scale with
-- effort or a high-effort turn gets truncated mid-thought. legacyBudget is the
-- budget_tokens fallback for pre-adaptive models (1024 minimum).
local EFFORT_LEVELS: { { name: string, api: string, hint: string, maxTokens: number, legacyBudget: number } } = {
	{ name = "Low",    api = "low",    hint = "fastest, cheapest",   maxTokens = 8192,  legacyBudget = 1024 },
	{ name = "Medium", api = "medium", hint = "balanced",            maxTokens = 16384, legacyBudget = 4096 },
	{ name = "High",   api = "high",   hint = "API default",         maxTokens = 32768, legacyBudget = 8192 },
	{ name = "Xhigh",  api = "xhigh",  hint = "long agentic work",   maxTokens = 64000, legacyBudget = 16384 },
	{ name = "Max",    api = "max",    hint = "no token constraints", maxTokens = 64000, legacyBudget = 24576 },
}
Settings.EFFORT_LEVELS = EFFORT_LEVELS

local pluginRef: Plugin = nil :: any
local state = {
	model = Claude.DEFAULT_MODEL,
	effort = 3,  -- High, matching the API default
	system = DEFAULT_SYSTEM,
	-- Off by default and deliberately not remembered as "on" by accident:
	-- `run` executes arbitrary Luau at plugin permission level.
	allowRun = false,
	-- Max searches per request; 0 disables the tool. Billed per search on top
	-- of tokens, so this is opt-in with an explicit ceiling rather than a
	-- boolean that could run away on a single question.
	webSearch = 0,
}

function Settings.Initialize(p: Plugin)
	pluginRef = p
	local model = p:GetSetting(KEY_MODEL)
	local effort = p:GetSetting(KEY_EFFORT)
	local system = p:GetSetting(KEY_SYSTEM)
	if type(model) == "string" and model ~= "" then state.model = model end
	-- A saved index from an older build could point at a level that no longer
	-- exists, or at the wrong one; validate rather than trust it.
	if type(effort) == "number" and EFFORT_LEVELS[effort] then state.effort = effort end
	if type(system) == "string" then state.system = system end
	state.allowRun = p:GetSetting(KEY_RUN) == true
	local searches = p:GetSetting(KEY_SEARCH)
	if type(searches) == "number" and searches >= 0 then state.webSearch = searches end
end

function Settings.model(): string return state.model end
function Settings.system(): string return state.system end
function Settings.effortName(): string return EFFORT_LEVELS[state.effort].name end

-- The value sent as output_config.effort on models that support it.
function Settings.effort(): string
	return EFFORT_LEVELS[state.effort].api
end

-- Fallback for pre-adaptive models; ignored elsewhere.
function Settings.thinkingBudget(): number
	return EFFORT_LEVELS[state.effort].legacyBudget
end

function Settings.maxTokens(): number
	return EFFORT_LEVELS[state.effort].maxTokens
end

function Settings.setModel(id: string)
	state.model = id
	pluginRef:SetSetting(KEY_MODEL, id)
end

function Settings.setEffort(index: number)
	if not EFFORT_LEVELS[index] then return end
	state.effort = index
	pluginRef:SetSetting(KEY_EFFORT, index)
end

function Settings.allowRun(): boolean
	return state.allowRun
end

function Settings.setAllowRun(enabled: boolean)
	state.allowRun = enabled
	pluginRef:SetSetting(KEY_RUN, enabled)
end

function Settings.webSearchMaxUses(): number
	return state.webSearch
end

function Settings.setWebSearch(maxUses: number)
	state.webSearch = maxUses
	pluginRef:SetSetting(KEY_SEARCH, maxUses)
end

function Settings.setSystem(text: string)
	state.system = text
	pluginRef:SetSetting(KEY_SYSTEM, text)
end

-- =============================================================================
-- Widgets
-- =============================================================================
local function sectionLabel(parent: Instance, text: string, order: number)
	make("TextLabel", {
		Parent = parent,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		FontFace = Theme.SANS_BOLD,
		TextSize = 11,
		TextColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		LayoutOrder = order,
	})
end

type Option = { id: any, label: string, hint: string? }

-- A dropdown that expands INLINE, pushing the content below it down. An overlay
-- popup would need absolute positioning and its own click-outside handling; the
-- list lives in a scrolling panel where growing downward is free.
local function dropdown(
	parent: Instance,
	order: number,
	options: { Option },
	getSelected: () -> any,
	onSelect: (any) -> ()
)
	local holder = make("Frame", {
		Parent = parent,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	})
	make("UIListLayout", { Parent = holder, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder })

	local function labelFor(id: any): string
		for _, option in ipairs(options) do
			if option.id == id then return option.label end
		end
		return tostring(id)
	end

	local trigger = make("TextButton", {
		Parent = holder,
		BackgroundColor3 = Theme.BG_DARK,
		BorderColor3 = Theme.BORDER,
		BorderSizePixel = 1,
		Size = UDim2.new(1, 0, 0, 28),
		FontFace = Theme.SANS,
		TextSize = Theme.SMALL_SIZE,
		TextColor3 = Theme.TEXT_HI,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		AutoButtonColor = true,
		LayoutOrder = 1,
	})
	make("UIPadding", { Parent = trigger, PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) })
	make("UICorner", { Parent = trigger, CornerRadius = UDim.new(0, 4) })

	local caret = make("TextLabel", {
		Parent = trigger,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 16, 1, 0),
		Position = UDim2.new(1, -6, 0, 0),
		FontFace = Theme.SANS,
		TextSize = 10,
		TextColor3 = Theme.TEXT_LO,
		Text = "▼",
	})

	local list = make("Frame", {
		Parent = holder,
		BackgroundColor3 = Theme.BG_DARK,
		BorderColor3 = Theme.BORDER,
		BorderSizePixel = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		LayoutOrder = 2,
	})
	make("UIListLayout", { Parent = list, SortOrder = Enum.SortOrder.LayoutOrder })
	make("UICorner", { Parent = list, CornerRadius = UDim.new(0, 4) })

	local function refresh()
		trigger.Text = labelFor(getSelected())
	end

	for i, option in ipairs(options) do
		local row = make("TextButton", {
			Parent = list,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 26),
			FontFace = Theme.SANS,
			TextSize = Theme.SMALL_SIZE,
			TextColor3 = Theme.TEXT_MED,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
			AutoButtonColor = true,
			LayoutOrder = i,
		})
		make("UIPadding", { Parent = row, PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) })

		local hintLabel = option.hint and make("TextLabel", {
			Parent = row,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 140, 1, 0),
			Position = UDim2.new(1, -140, 0, 0),
			FontFace = Theme.SANS,
			TextSize = 10,
			TextColor3 = Theme.TEXT_LO,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = option.hint,
		}) or nil

		local function repaint()
			local on = getSelected() == option.id
			row.Text = (on and "✓ " or "   ") .. option.label
			row.TextColor3 = on and Theme.ACCENT or Theme.TEXT_MED
			if hintLabel then hintLabel.Visible = true end
		end
		repaint()

		row.MouseButton1Click:Connect(function()
			onSelect(option.id)
			list.Visible = false
			caret.Text = "▼"
			refresh()
			for _, sibling in ipairs(list:GetChildren()) do
				if sibling:IsA("TextButton") then
					sibling:SetAttribute("repaint", os.clock())
				end
			end
		end)
		-- Each row owns its own selected-state predicate, so no row needs to know
		-- about its siblings; the attribute is just the nudge to re-evaluate.
		row:GetAttributeChangedSignal("repaint"):Connect(repaint)
	end

	trigger.MouseButton1Click:Connect(function()
		list.Visible = not list.Visible
		caret.Text = list.Visible and "▲" or "▼"
	end)

	refresh()
end

-- =============================================================================
-- Panel
-- =============================================================================
export type StatusRow = { label: string, value: string }

-- `statusProvider` is supplied by the entry point so Settings doesn't have to
-- know about OAuth, the Terminal or the Agent.
function Settings.mountPanel(parent: Instance, statusProvider: () -> { StatusRow }): (boolean?) -> ()
	-- Full-bleed scrim: dims the console and catches clicks outside the card.
	local scrim = make("TextButton", {
		Name = "SettingsScrim",
		Parent = parent,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		-- The scrim is a SIBLING of the console root and the autocomplete list,
		-- so it still needs a number to sit above them. Everything inside the card
		-- is a descendant and layers by hierarchy under ZIndexBehavior.Sibling.
		ZIndex = 60,
	})

	local card = make("Frame", {
		Name = "SettingsCard",
		Parent = scrim,
		BackgroundColor3 = Theme.BG_SURFACE,
		BorderColor3 = Theme.BORDER,
		BorderSizePixel = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 38),
		Size = UDim2.new(0, 380, 1, -56),
	})
	make("UICorner", { Parent = card, CornerRadius = UDim.new(0, 8) })
	-- Docked at the bottom of Studio the widget can be very short or very tall;
	-- clamp so the card never outgrows a useful size or collapses to nothing.
	make("UISizeConstraint", {
		Parent = card,
		MinSize = Vector2.new(280, 160),
		MaxSize = Vector2.new(380, 460),
	})

	local header = make("Frame", {
		Parent = card,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34),
	})
	make("TextLabel", {
		Parent = header,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -46, 1, 0),
		Position = UDim2.new(0, 14, 0, 0),
		FontFace = Theme.SANS_BOLD,
		TextSize = 13,
		TextColor3 = Theme.TEXT_HI,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Settings",
	})
	local closeButton = make("TextButton", {
		Parent = header,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 32, 1, 0),
		Position = UDim2.new(1, -34, 0, 0),
		FontFace = Theme.SANS,
		TextSize = 15,
		TextColor3 = Theme.TEXT_MED,
		Text = "✕",
	})
	make("Frame", {
		Parent = header,
		BackgroundColor3 = Theme.BORDER,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.new(0, 0, 1, -1),
	})

	local scroll = make("ScrollingFrame", {
		Parent = card,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -34),
		Position = UDim2.new(0, 0, 0, 34),
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.TEXT_LO,
	})
	make("UIListLayout", { Parent = scroll, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder })
	make("UIPadding", {
		Parent = scroll,
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 14),
	})

	-- Status ------------------------------------------------------------------
	sectionLabel(scroll, "STATUS", 1)
	local statusBox = make("Frame", {
		Parent = scroll,
		BackgroundColor3 = Theme.BG_DARK,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
	})
	make("UICorner", { Parent = statusBox, CornerRadius = UDim.new(0, 4) })
	make("UIListLayout", { Parent = statusBox, SortOrder = Enum.SortOrder.LayoutOrder })
	make("UIPadding", {
		Parent = statusBox,
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
	})

	local function refreshStatus()
		for _, child in ipairs(statusBox:GetChildren()) do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		for i, row in ipairs(statusProvider()) do
			local line = make("Frame", {
				Parent = statusBox,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 18),
				LayoutOrder = i,
			})
			make("TextLabel", {
				Parent = line,
				BackgroundTransparency = 1,
				Size = UDim2.new(0.4, 0, 1, 0),
				FontFace = Theme.SANS,
				TextSize = 11,
				TextColor3 = Theme.TEXT_LO,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = row.label,
			})
			make("TextLabel", {
				Parent = line,
				BackgroundTransparency = 1,
				Size = UDim2.new(0.6, 0, 1, 0),
				Position = UDim2.new(0.4, 0, 0, 0),
				FontFace = Theme.MONO,
				TextSize = 11,
				TextColor3 = Theme.TEXT_MED,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Right,
				Text = row.value,
			})
		end
	end

	-- Model -------------------------------------------------------------------
	sectionLabel(scroll, "MODEL", 3)
	local modelOptions: { Option } = {}
	for _, entry in ipairs(Claude.MODELS) do
		table.insert(modelOptions, { id = entry.id, label = entry.label })
	end
	dropdown(scroll, 4, modelOptions, Settings.model, function(id)
		Settings.setModel(id :: string)
		refreshStatus()
	end)

	-- Thinking budget ---------------------------------------------------------
	sectionLabel(scroll, "EFFORT", 5)
	local effortOptions: { Option } = {}
	for index, level in ipairs(EFFORT_LEVELS) do
		table.insert(effortOptions, { id = index, label = level.name, hint = level.hint })
	end
	dropdown(scroll, 6, effortOptions, function() return state.effort end, function(id)
		Settings.setEffort(id :: number)
		refreshStatus()
	end)
	make("TextLabel", {
		Parent = scroll,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = Theme.SANS,
		TextSize = 10,
		TextColor3 = Theme.TEXT_LO,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "output_config.effort — controls total token spend across thinking, "
			.. "prose and tool calls. At lower effort Claude may skip thinking "
			.. "entirely on easy inputs; that is expected, not a bug.",
		LayoutOrder = 7,
	})

	-- Web search --------------------------------------------------------------
	sectionLabel(scroll, "WEB SEARCH", 8)
	dropdown(scroll, 9, {
		{ id = 0,  label = "Disabled" },
		{ id = 3,  label = "Up to 3 searches",  hint = "per message" },
		{ id = 5,  label = "Up to 5 searches",  hint = "per message" },
		{ id = 10, label = "Up to 10 searches", hint = "per message" },
	}, Settings.webSearchMaxUses, function(id)
		Settings.setWebSearch(id :: number)
	end)
	make("TextLabel", {
		Parent = scroll,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = Theme.SANS,
		TextSize = 10,
		TextColor3 = Theme.TEXT_LO,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Anthropic runs the searches server-side and cites its sources. "
			.. "Useful for current Roblox API changes and engine docs. Billed per "
			.. "search in addition to tokens.",
		LayoutOrder = 10,
	})

	-- Code execution ----------------------------------------------------------
	sectionLabel(scroll, "RUN CODE", 11)
	dropdown(scroll, 12, {
		{ id = false, label = "Disabled", hint = "recommended" },
		{ id = true,  label = "Enabled",  hint = "Claude can execute Luau" },
	}, Settings.allowRun, function(id)
		Settings.setAllowRun(id :: boolean)
	end)
	make("TextLabel", {
		Parent = scroll,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = Theme.SANS,
		TextSize = 10,
		TextColor3 = Theme.TEXT_LO,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Lets Claude execute Luau to test and benchmark code. Runs at plugin "
			.. "permission level with no timeout — an unbounded loop will freeze Studio. "
			.. "Effects are undoable; enable only in a place you can afford to lose.",
		LayoutOrder = 13,
	})

	-- System prompt -----------------------------------------------------------
	sectionLabel(scroll, "SYSTEM PROMPT", 14)
	local promptBox = make("TextBox", {
		Parent = scroll,
		BackgroundColor3 = Theme.BG_DARK,
		BorderColor3 = Theme.BORDER,
		BorderSizePixel = 1,
		Size = UDim2.new(1, 0, 0, 96),
		FontFace = Theme.MONO,
		TextSize = 11,
		TextColor3 = Theme.TEXT_HI,
		TextWrapped = true,
		MultiLine = true,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = state.system,
		LayoutOrder = 15,
	})
	make("UICorner", { Parent = promptBox, CornerRadius = UDim.new(0, 4) })
	make("UIPadding", {
		Parent = promptBox,
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		PaddingTop = UDim.new(0, 6),
	})
	-- Save on blur, not per keystroke: SetSetting writes to disk.
	promptBox.FocusLost:Connect(function()
		Settings.setSystem(promptBox.Text)
	end)

	local resetButton = make("TextButton", {
		Parent = scroll,
		BackgroundColor3 = Theme.BG_INPUT,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 130, 0, 24),
		FontFace = Theme.SANS,
		TextSize = 11,
		TextColor3 = Theme.TEXT_MED,
		Text = "Reset to default",
		LayoutOrder = 16,
	})
	make("UICorner", { Parent = resetButton, CornerRadius = UDim.new(0, 4) })
	resetButton.MouseButton1Click:Connect(function()
		promptBox.Text = DEFAULT_SYSTEM
		Settings.setSystem(DEFAULT_SYSTEM)
	end)

	-- Toggle ------------------------------------------------------------------
	local function toggle(visible: boolean?)
		local shouldShow = if visible == nil then not scrim.Visible else visible
		if shouldShow then
			refreshStatus()
		else
			-- Closing without blurring the box would discard an unsaved edit.
			Settings.setSystem(promptBox.Text)
		end
		scrim.Visible = shouldShow
	end

	closeButton.MouseButton1Click:Connect(function() toggle(false) end)
	-- Clicking the scrim closes; clicks on the card don't reach it, since the
	-- card is a child that consumes them.
	scrim.MouseButton1Click:Connect(function() toggle(false) end)

	return toggle
end

return Settings
