--!strict
-- Settings.luau: persisted preferences, shown in a floating popup.
--
-- State lives in plugin:SetSetting, so it survives Studio restarts.
--
-- EFFORT is a real, first-class parameter on both providers, spelled
-- differently by each — Anthropic takes output_config.effort, OpenRouter takes
-- reasoning.effort — and carrying the same five levels either way. It governs
-- total token spend for the whole response: prose, tool calls, and thinking
-- alike. "high" is the API default.
--
-- The level is stored globally and always kept, the way /effort does it in
-- Claude Code, which never asks whether the model supports the parameter. The
-- gate is at send time: the provider drops it for a model that does not take
-- one, so picking such a model makes the setting do nothing and switching back
-- makes it matter again. Nothing is substituted in the meantime — a thinking
-- budget is not an effort dial.
--
-- MODEL is stored per provider. An id belongs to exactly one of them, so one
-- shared slot would hand OpenRouter a Claude id the moment you switched.

local Theme = require(script.Parent:WaitForChild("Theme"))
-- Reaches into agent/ for the model list only. Settings is the one module that
-- is genuinely half UI and half configuration; if it ever splits, the prefs half
-- is what belongs next to the agent.
local Provider = require(script.Parent.Parent:WaitForChild("agent"):WaitForChild("Provider"))

local make = Theme.make

local Settings = {}

local KEY_MODEL  = "cc_model"
local KEY_EFFORT = "cc_effort"
local KEY_SYSTEM = "cc_system"
local KEY_RUN    = "cc_allow_run"
local KEY_SEARCH = "cc_web_search"

local DEFAULT_SYSTEM = "we are in edit mode roblox studio, do not do anything from scratch"
Settings.DEFAULT_SYSTEM = DEFAULT_SYSTEM

-- Effort is one string on the wire and nothing else. It used to carry a
-- per-level max_tokens and a per-level budget_tokens beside it; both were
-- invented. max_tokens is a ceiling, not a reservation — an unused one costs
-- nothing — and effort governs how hard the model thinks, not how long the
-- answer may be, so scaling it meant a Low-effort turn truncated mid-`write` on
-- a long file. budget_tokens does not track effort either: it is the ceiling
-- minus one, on the only models that still take it. Both live in the provider
-- now, which is the only thing that should know a model's limits.
local EFFORT_LEVELS: { { name: string, api: string, hint: string } } = {
	{ name = "Low",    api = "low",    hint = "fastest, cheapest" },
	{ name = "Medium", api = "medium", hint = "balanced" },
	{ name = "High",   api = "high",   hint = "API default" },
	{ name = "Xhigh",  api = "xhigh",  hint = "long agentic work" },
	{ name = "Max",    api = "max",    hint = "no token constraints" },
}
Settings.EFFORT_LEVELS = EFFORT_LEVELS

local pluginRef: Plugin = nil :: any
local state = {
	-- Resolved in Initialize, not here: main.luau requires this module before it
	-- calls Provider.Initialize, so there is no wire to ask yet.
	model = "",
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

-- One slot per provider. Bare `cc_model` was the slot when there was only one.
local function modelKey(): string
	return KEY_MODEL .. "_" .. Provider.id
end

-- Loads the model belonging to whichever provider is active now. Called at
-- startup and again after a switch, because a stored id is only meaningful to
-- the provider that stored it.
function Settings.reloadModel()
	local saved = pluginRef and pluginRef:GetSetting(modelKey())
	-- One-time migration: the choice used to live under a single global key,
	-- from when Claude was the only provider. Read it so an existing install
	-- does not silently reset to the default on first launch after this.
	if (type(saved) ~= "string" or saved == "") and Provider.id == "anthropic" then
		saved = pluginRef and pluginRef:GetSetting(KEY_MODEL)
	end
	local wire = Provider.wire
	local usable = type(saved) == "string" and saved ~= ""
		and (wire.acceptsModelId == nil or wire.acceptsModelId(saved))
	state.model = if usable then saved :: string else wire.DEFAULT_MODEL
end

function Settings.Initialize(p: Plugin)
	pluginRef = p
	local effort = p:GetSetting(KEY_EFFORT)
	local system = p:GetSetting(KEY_SYSTEM)
	Settings.reloadModel()
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

function Settings.setModel(id: string)
	state.model = id
	pluginRef:SetSetting(modelKey(), id)
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

-- Widgets
local function sectionLabel(parent: Instance, text: string, order: number)
	make("TextLabel", {
		Parent = parent,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		FontFace = Theme.SANS_BOLD,
		TextSize = 13,
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
		Size = UDim2.new(1, 0, 0, 32),
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
		TextSize = 12,
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
			Size = UDim2.new(1, 0, 0, 30),
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
			TextSize = 12,
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

-- Panel
-- `bar` is a 0..1 fraction; rows that carry one get a progress track drawn under
-- the label/value line.
export type StatusRow = { label: string, value: string, bar: number? }

-- `statusProvider` is supplied by the entry point so Settings doesn't have to
-- know about OAuth, the Terminal or the Agent.
function Settings.mountPanel(
	parent: Instance,
	statusProvider: () -> { StatusRow }
): ((boolean?) -> (), () -> ())
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
		-- Centred rather than pinned to the top-right corner: it can then be wider
		-- than a corner card without crowding the edge, and the eye lands on it.
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -80, 1, -60),
	})
	make("UICorner", { Parent = card, CornerRadius = UDim.new(0, 4) })
	-- The widget can be very short or very wide depending on where it is docked;
	-- clamp so the card never outgrows a readable measure or collapses to nothing.
	make("UISizeConstraint", {
		Parent = card,
		MinSize = Vector2.new(300, 200),
		MaxSize = Vector2.new(520, 640),
	})

	local header = make("Frame", {
		Parent = card,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
	})
	make("TextLabel", {
		Parent = header,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -56, 1, 0),
		Position = UDim2.new(0, 18, 0, 0),
		FontFace = Theme.SANS_BOLD,
		TextSize = 15,
		TextColor3 = Theme.TEXT_HI,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Settings",
	})
	local closeButton = make("TextButton", {
		Parent = header,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 36, 1, 0),
		Position = UDim2.new(1, -40, 0, 0),
		FontFace = Theme.ICON,
		TextSize = 16,
		TextColor3 = Theme.TEXT_MED,
		Text = "x-small",
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
		Size = UDim2.new(1, 0, 1, -40),
		Position = UDim2.new(0, 0, 0, 40),
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.TEXT_LO,
	})
	make("UIListLayout", { Parent = scroll, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })
	make("UIPadding", {
		Parent = scroll,
		PaddingLeft = UDim.new(0, 18),
		PaddingRight = UDim.new(0, 18),
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 18),
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
				-- A bar row keeps the same label/value line and hangs a 4px track
				-- underneath it.
				Size = UDim2.new(1, 0, 0, row.bar and 29 or 21),
				LayoutOrder = i,
			})
			make("TextLabel", {
				Parent = line,
				BackgroundTransparency = 1,
				Size = UDim2.new(0.4, 0, 0, 21),
				FontFace = Theme.SANS,
				TextSize = 13,
				TextColor3 = Theme.TEXT_LO,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = row.label,
			})
			make("TextLabel", {
				Parent = line,
				BackgroundTransparency = 1,
				Size = UDim2.new(0.6, 0, 0, 21),
				Position = UDim2.new(0.4, 0, 0, 0),
				FontFace = Theme.MONO,
				TextSize = 13,
				TextColor3 = Theme.TEXT_MED,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Right,
				Text = row.value,
			})
			if row.bar then
				local fraction = math.clamp(row.bar, 0, 1)
				local track = make("Frame", {
					Parent = line,
					BackgroundColor3 = Theme.BG_SURFACE,
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, 4),
					Position = UDim2.new(0, 0, 0, 22),
				})
				make("UICorner", { Parent = track, CornerRadius = UDim.new(0, 2) })
				local fill = make("Frame", {
					Parent = track,
					-- Red once the window is nearly spent, so a full bar reads as a
					-- warning without needing a legend.
					BackgroundColor3 = fraction >= 0.9 and Theme.ERR_CLR or Theme.BAR_CLR,
					BorderSizePixel = 0,
					Size = UDim2.fromScale(fraction, 1),
				})
				make("UICorner", { Parent = fill, CornerRadius = UDim.new(0, 2) })
			end
		end
	end

	-- Neither MODEL nor EFFORT is here. Both live on the chip at the right of the
	-- input row, the model on its first page, effort behind it, one click from
	-- where you type. A second copy of either is just another place for the two to
	-- disagree.

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
		TextSize = 12,
		TextColor3 = Theme.TEXT_LO,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Server-side, with citations. Billed per search on top of tokens.",
		LayoutOrder = 10,
	})

	-- Code execution ----------------------------------------------------------
	sectionLabel(scroll, "RUN CODE", 11)
	dropdown(scroll, 12, {
		{ id = false, label = "Disabled", hint = "recommended" },
		{ id = true,  label = "Enabled",  hint = "the agent can execute Luau" },
	}, Settings.allowRun, function(id)
		Settings.setAllowRun(id :: boolean)
	end)
	make("TextLabel", {
		Parent = scroll,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = Theme.SANS,
		TextSize = 12,
		TextColor3 = Theme.TEXT_LO,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		-- The freeze warning stays: it is the one thing that can cost the user work.
		Text = "Runs Luau at plugin level, no timeout — an infinite loop freezes Studio.",
		LayoutOrder = 13,
	})

	-- System prompt -----------------------------------------------------------
	sectionLabel(scroll, "SYSTEM PROMPT", 14)
	local promptBox = make("TextBox", {
		Parent = scroll,
		BackgroundColor3 = Theme.BG_DARK,
		BorderColor3 = Theme.BORDER,
		BorderSizePixel = 1,
		Size = UDim2.new(1, 0, 0, 120),
		FontFace = Theme.MONO,
		TextSize = 13,
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
		Size = UDim2.new(0, 150, 0, 28),
		FontFace = Theme.SANS,
		TextSize = 13,
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

	-- refreshStatus rides along so the caller can redraw the STATUS rows when an
	-- async source (the usage endpoint) lands after the panel is already open.
	return toggle, refreshStatus
end

return Settings
