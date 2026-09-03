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
local KEY_TOOLS  = "cc_tools_off"

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
	-- Tools the reader has switched OFF, by name. Stored as the exceptions rather
	-- than the full set so a tool added later is on by default: an allowlist would
	-- silently withhold every new tool from anyone with an existing install, and
	-- the failure would look like the tool not working rather than a stale setting.
	toolsOff = {} :: { [string]: boolean },
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
	-- Persisted as an array because a settings value round-trips through JSON,
	-- where a set with no entries encodes as `[]` and comes back as something
	-- that is not a set. Rebuilt into one here, which is the shape every reader
	-- wants.
	-- Cast, so this call site does not widen GetSetting's inferred return for
	-- every other one: without it the analyzer folds `{unknown}` into the type and
	-- the unrelated `== true` read above starts failing to typecheck.
	local off = p:GetSetting(KEY_TOOLS) :: any
	if type(off) == "table" then
		for _, name in ipairs(off) do
			if type(name) == "string" then state.toolsOff[name] = true end
		end
	end
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

-- Default ON. See state.toolsOff for why the store holds the exceptions.
function Settings.toolEnabled(name: string): boolean
	return not state.toolsOff[name]
end

function Settings.setToolEnabled(name: string, enabled: boolean)
	state.toolsOff[name] = if enabled then nil else true
	local off: { string } = {}
	for toolName in pairs(state.toolsOff) do
		off[#off + 1] = toolName
	end
	-- Sorted, so writing the same set twice writes the same value: pairs order is
	-- undefined, and a settings write re-serialises the whole store.
	table.sort(off)
	pluginRef:SetSetting(KEY_TOOLS, off)
end

function Settings.setWebSearch(maxUses: number)
	state.webSearch = maxUses
	pluginRef:SetSetting(KEY_SEARCH, maxUses)
end

function Settings.setSystem(text: string)
	-- Unchanged text writes nothing. The panel calls this on EVERY close,
	-- whether or not the box was touched, and a plugin's settings are one JSON
	-- object: there is no partial write, so setting any key re-serialises every
	-- key. With sessions in the same store that is megabytes through the main
	-- thread, which is long enough for Studio to offer to stop the plugin —
	-- closing the settings panel was doing exactly that.
	if text == state.system then return end
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
--
-- `segments` turns the row's bar into a stacked one: the same track, the same
-- total width, divided by where the space went. Each fraction is of the WHOLE
-- track, not of the filled part, so the segments end exactly where the plain
-- fill would have and what is left is genuinely free. `swatch` is the legend
-- half — a row that names one of those segments carries its colour.
-- `barValue` sits to the RIGHT of the track rather than above it, which is what
-- splits the two questions a usage row answers: `value` at the top right says
-- when the window comes back, `barValue` beside the bar says how much is gone.
-- Both on one line meant the more urgent half was whichever the formatter
-- happened to put first.
--
-- `onClick` makes the whole row a button and redraws the card afterwards. Used
-- for actions that belong beside the data they act on — a Refresh next to the
-- usage bars, rather than a chrome button that has to explain what it refreshes.
-- `heading` makes the row a group label instead of a statistic — same box, same
-- list, so a page can be sectioned without a second container and a second
-- LayoutOrder space to keep in step with it.
--
-- `toggle` draws a switch in place of the value text. A word reading "on" is
-- something to parse per row; a row of switches is a state you take in at a
-- glance, which is the whole point of listing the tools together.
export type StatusRow = {
	label: string,
	value: string,
	bar: number?,
	barValue: string?,
	segments: { { fraction: number, color: Color3 } }?,
	swatch: Color3?,
	heading: boolean?,
	toggle: boolean?,
	onClick: (() -> ())?,
}

-- Which tab's rows the provider is being asked for. Asked ONLY for the page on
-- screen, so a page's rows cost nothing while it is hidden — which is what lets
-- the Context page do real work to build its own.
export type Page = "settings" | "usage" | "context"

-- `statusProvider` is supplied by the entry point so Settings doesn't have to
-- know about OAuth, the Terminal or the Agent.
-- `statusProvider` MUST be pure — it is called on every redraw, including the
-- redraw a landing network request triggers, so a fetch inside it is a feedback
-- loop that hammers the endpoint. Anything that needs data fetched belongs in
-- `onPageShown`, which fires only when a page genuinely becomes visible: the
-- panel opening, or a tab being clicked. Never on a plain refresh.
function Settings.mountPanel(
	parent: Instance,
	statusProvider: (Page) -> { StatusRow },
	onPageShown: ((Page) -> ())?
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

	-- The card has no UIListLayout — header, sticky row, tabs and scroll are all
	-- positioned by hand against each other, so the offsets come off one sum
	-- rather than being written out at each site. The previous version had the
	-- header's 40 typed into the scroll's Size AND its Position, which is two
	-- places to miss; this is now four strips deep.
	local HEADER_H, TABS_H = 40, 30
	local CHROME_H = HEADER_H + TABS_H

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
	--
	-- The floor is derived from the chrome, not typed. Header + sticky row + tabs
	-- is 96px before a single row is drawn, and against the old flat 200 that left
	-- barely a hundred pixels of content in a short docked widget — the tabs paid
	-- for themselves out of the thing they were meant to make readable. 160 is
	-- room for the seven rows the Context page draws.
	make("UISizeConstraint", {
		Parent = card,
		MinSize = Vector2.new(300, CHROME_H + 160),
		MaxSize = Vector2.new(520, 640),
	})

	local header = make("Frame", {
		Parent = card,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HEADER_H),
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

	local tabStrip = make("Frame", {
		Parent = card,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, TABS_H),
		Position = UDim2.new(0, 0, 0, HEADER_H),
	})
	make("Frame", {
		Parent = tabStrip,
		BackgroundColor3 = Theme.BORDER,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.new(0, 0, 1, -1),
	})

	local scroll = make("ScrollingFrame", {
		Parent = card,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -CHROME_H),
		Position = UDim2.new(0, 0, 0, CHROME_H),
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.TEXT_LO,
	})
	-- Kept even though the scroll now holds three children of which one is ever
	-- visible: a UIListLayout skips Visible = false children when it measures, and
	-- that is what makes AutomaticCanvasSize follow the ACTIVE page instead of the
	-- tallest one. Without it the three pages also stack at the origin rather than
	-- being laid out at all.
	make("UIListLayout", { Parent = scroll, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder })
	make("UIPadding", {
		Parent = scroll,
		PaddingLeft = UDim.new(0, 18),
		PaddingRight = UDim.new(0, 18),
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 18),
	})

	-- Pages
	-- One container per tab, all three parented to the scroll and only one
	-- Visible. The UIListLayout that used to live on the scroll moves ONTO each
	-- page: content is a level deeper now, and without its own layout a page's
	-- children stack at the origin with no 8px gap. AutomaticSize.Y for the same
	-- reason — statusBox grows with however many rows its page returns, and a
	-- fixed-height parent collapses it to nothing.
	--
	-- A hidden page is skipped by the scroll's own layout, so the canvas measures
	-- the active page alone and scrolls to fit it.
	local function makePage(): Frame
		local page = make("Frame", {
			Parent = scroll,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false,
		})
		make("UIListLayout", {
			Parent = page,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		})
		return page
	end
	local pageSettings, pageUsage, pageContext = makePage(), makePage(), makePage()

	-- The rows box, built once and re-parented per page rather than one per tab:
	-- only ever one page is visible, so only one is ever filled, and three boxes
	-- would be three things for refreshStatus to keep in step.
	local statusBox = make("Frame", {
		BackgroundColor3 = Theme.BG_DARK,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1,
		Parent = pageUsage,
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

	-- Sticky across openings: someone who left it on Context is watching the
	-- window and wants it again next time, not a reset to Settings.
	local activePage: Page = "settings"

	-- Declared above fillRows, which calls it after an onClick row is pressed, and
	-- assigned far below once the pages and tabs it drives exist. A `local` after
	-- its use site is a nil global, not that local.
	local refreshStatus: () -> ()

	-- Draws one provider page's rows into a box. Shared by the sticky row above
	-- the tabs and by the active page below them, because the two differ only in
	-- which page they ask for and where the result lands.
	local function fillRows(box: Frame, page: Page)
		for _, child in ipairs(box:GetChildren()) do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		for i, row in ipairs(statusProvider(page)) do
			-- A bar row keeps the same label/value line and hangs the track
			-- underneath it. 6 rather than the 4 it was: at 4 the corner radius ate
			-- the whole bar and the stacked slivers rounded away to nothing. 8 was
			-- too heavy next to 13px text.
			local BAR_H = 6
			local line = make(if row.onClick then "TextButton" else "Frame", {
				Parent = box,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, if row.bar then 21 + BAR_H + 4 else 21),
				LayoutOrder = i,
				-- A TextButton draws its own centred label over the two below it, so
				-- the row's text stays theirs to render.
				Text = if row.onClick then "" else nil,
				AutoButtonColor = if row.onClick then false else nil,
			})
			if row.onClick then
				local onClick = row.onClick :: () -> ()
				;(line :: TextButton).MouseButton1Click:Connect(function()
					onClick()
					refreshStatus()
				end)
			end
			-- A legend dot, inset so the label still lines up with the rows above
			-- it. A Frame rather than a coloured glyph in the text: the label is
			-- one TextLabel with one colour, and turning RichText on for every
			-- status row to tint one character would make a `<` in any other row
			-- into markup.
			local labelInset = 0
			if row.swatch then
				labelInset = 12
				local dot = make("Frame", {
					Parent = line,
					BackgroundColor3 = row.swatch,
					BorderSizePixel = 0,
					Size = UDim2.new(0, 7, 0, 7),
					Position = UDim2.new(0, 0, 0, 7),
				})
				make("UICorner", { Parent = dot, CornerRadius = UDim.new(1, 0) })
			end
			make("TextLabel", {
				Parent = line,
				BackgroundTransparency = 1,
				-- A heading owns the whole width; there is no value beside it.
				Size = UDim2.new(if row.heading then 1 else 0.4, -labelInset, 0, 21),
				Position = UDim2.new(0, labelInset, 0, 0),
				FontFace = if row.heading then Theme.SANS_BOLD else Theme.SANS,
				TextSize = 13,
				TextColor3 = Theme.TEXT_LO,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = row.label,
			})
			if row.toggle ~= nil then
				-- A pill and a knob, at the right edge where the value would be. Two
				-- Frames rather than an image: it is two rounded rectangles, and an
				-- asset id is a thing to upload, version and get wrong.
				local on = row.toggle
				local TRACK_W, TRACK_H, PAD = 26, 14, 2
				local track = make("Frame", {
					Parent = line,
					BackgroundColor3 = if on then Theme.ACCENT else Theme.BG_SURFACE,
					BorderSizePixel = 0,
					Size = UDim2.new(0, TRACK_W, 0, TRACK_H),
					-- Centred against the 21px label line beside it.
					Position = UDim2.new(1, -TRACK_W, 0, (21 - TRACK_H) // 2),
				})
				make("UICorner", { Parent = track, CornerRadius = UDim.new(1, 0) })
				local knob = make("Frame", {
					Parent = track,
					-- Cream on the accent, muted on the empty track: the knob has to
					-- stay legible against both fills, so it changes with them.
					BackgroundColor3 = if on then Theme.TEXT_HI else Theme.TEXT_LO,
					BorderSizePixel = 0,
					Size = UDim2.new(0, TRACK_H - PAD * 2, 0, TRACK_H - PAD * 2),
					Position = if on
						then UDim2.new(1, -(TRACK_H - PAD), 0, PAD)
						else UDim2.new(0, PAD, 0, PAD),
				})
				make("UICorner", { Parent = knob, CornerRadius = UDim.new(1, 0) })
			else
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
			end
			if row.bar then
				local fraction = math.clamp(row.bar, 0, 1)
				-- The track gives up its right end to barValue when there is one, so
				-- the number sits ON the bar's line instead of above it. Offset in
				-- pixels rather than scale: the text is a fixed few characters wide
				-- and a scale reservation would leave a gap on a wide panel and clip
				-- on a narrow one.
				local barInset = if row.barValue then 74 else 0
				local track = make("Frame", {
					Parent = line,
					BackgroundColor3 = Theme.BG_SURFACE,
					BorderSizePixel = 0,
					Size = UDim2.new(1, -barInset, 0, BAR_H),
					Position = UDim2.new(0, 0, 0, 24),
				})
				make("UICorner", { Parent = track, CornerRadius = UDim.new(0, BAR_H // 2) })
				if row.barValue then
					-- Exactly the track's box, so the number is centred on the bar
					-- rather than floating above it. The text is taller than 6px and
					-- overflows the box evenly top and bottom, which is what centres
					-- it — the box is an alignment guide, not a clip.
					make("TextLabel", {
						Parent = line,
						BackgroundTransparency = 1,
						Size = UDim2.new(0, barInset - 8, 0, BAR_H),
						Position = UDim2.new(1, -(barInset - 8), 0, 24),
						FontFace = Theme.MONO,
						TextSize = 11,
						TextColor3 = Theme.TEXT_MED,
						TextXAlignment = Enum.TextXAlignment.Right,
						TextYAlignment = Enum.TextYAlignment.Center,
						Text = row.barValue,
					})
				end
				if row.segments then
					-- Stacked. The rounding comes from the track clipping its
					-- children, so a segment is a plain rectangle and only the two
					-- ends of the WHOLE bar are rounded — corners on each segment
					-- would put a notch at every join.
					track.ClipsDescendants = true
					local offset = 0
					for index, segment in ipairs(row.segments) do
						local width = math.clamp(segment.fraction, 0, 1 - offset)
						if width > 0 then
							make("Frame", {
								Parent = track,
								BackgroundColor3 = segment.color,
								BorderSizePixel = 0,
								Size = UDim2.fromScale(width, 1),
								Position = UDim2.fromScale(offset, 0),
								LayoutOrder = index,
							})
							offset += width
						end
					end
				else
					local fill = make("Frame", {
						Parent = track,
						-- Red once the window is nearly spent, so a full bar reads as
						-- a warning without needing a legend.
						BackgroundColor3 = fraction >= 0.9 and Theme.ERR_CLR or Theme.BAR_CLR,
						BorderSizePixel = 0,
						Size = UDim2.fromScale(fraction, 1),
					})
					make("UICorner", { Parent = fill, CornerRadius = UDim.new(0, BAR_H // 2) })
				end
			end
		end
	end

	local PAGES: { { id: Page, label: string, frame: Frame } } = {
		{ id = "settings", label = "Settings", frame = pageSettings },
		{ id = "usage", label = "Usage", frame = pageUsage },
		{ id = "context", label = "Context", frame = pageContext },
	}

	local tabButtons: { TextButton } = {}
	local underline = make("Frame", {
		Parent = tabStrip,
		BackgroundColor3 = Theme.ACCENT,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 0, 2),
		Position = UDim2.new(0, 0, 1, -2),
	})

	local TAB_W = 76
	for index, tab in ipairs(PAGES) do
		local button = make("TextButton", {
			Parent = tabStrip,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Size = UDim2.new(0, TAB_W, 1, -2),
			Position = UDim2.new(0, 18 + (index - 1) * TAB_W, 0, 0),
			FontFace = Theme.SANS,
			TextSize = 13,
			TextColor3 = Theme.TEXT_LO,
			Text = tab.label,
		})
		tabButtons[index] = button
		button.MouseButton1Click:Connect(function()
			if activePage == tab.id then return end
			activePage = tab.id
			refreshStatus()
			if onPageShown then onPageShown(tab.id) end
		end)
	end

	refreshStatus = function()
		for index, tab in ipairs(PAGES) do
			local active = tab.id == activePage
			tab.frame.Visible = active
			tabButtons[index].TextColor3 = if active then Theme.TEXT_HI else Theme.TEXT_LO
			if active then
				underline.Size = UDim2.new(0, TAB_W, 0, 2)
				underline.Position = UDim2.new(0, 18 + (index - 1) * TAB_W, 1, -2)
				-- Only the visible page's rows are built, which is the whole point of
				-- the split: Agent.contextBreakdown walks the conversation and encodes
				-- the tool schemas, and it is not reached at all from another tab.
				statusBox.Parent = tab.frame
				fillRows(statusBox, tab.id)
			end
		end
	end

	-- Neither MODEL nor EFFORT is here. Both live on the chip at the right of the
	-- input row, the model on its first page, effort behind it, one click from
	-- where you type. A second copy of either is just another place for the two to
	-- disagree.

	-- Web search ----------------------------------------------------------------
	-- Stays a dropdown while every other tool is a switch, because it is the only
	-- one that is not a boolean: it bills per search on top of tokens, so the
	-- setting is a ceiling and picking the number IS the decision. Run-code went
	-- the other way and is a toggle in the tool list now; what both shed is the
	-- wrapped paragraph that used to sit under each.
	sectionLabel(pageSettings, "WEB SEARCH", 2)
	dropdown(pageSettings, 3, {
		{ id = 0,  label = "Disabled" },
		{ id = 3,  label = "Up to 3 searches",  hint = "per message" },
		{ id = 5,  label = "Up to 5 searches",  hint = "per message" },
		{ id = 10, label = "Up to 10 searches", hint = "per message" },
	}, Settings.webSearchMaxUses, function(id)
		Settings.setWebSearch(id :: number)
	end)

	-- System prompt -----------------------------------------------------------
	sectionLabel(pageSettings, "SYSTEM PROMPT", 4)
	local promptBox = make("TextBox", {
		Parent = pageSettings,
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
		LayoutOrder = 5,
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
		Parent = pageSettings,
		BackgroundColor3 = Theme.BG_INPUT,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 150, 0, 28),
		FontFace = Theme.SANS,
		TextSize = 13,
		TextColor3 = Theme.TEXT_MED,
		Text = "Reset to default",
		LayoutOrder = 6,
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
			-- After the draw, not before: whatever this kicks off redraws when it
			-- lands, and the panel should be on screen with its last known values
			-- rather than blank until the network answers.
			if onPageShown then onPageShown(activePage) end
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
