--!strict
-- Console.luau — the scrolling output area.
--
-- Assistant replies are rendered as real GUI objects, one per Markdown block,
-- rather than as one big RichText string. That buys three things the string
-- approach could not have:
--   * a malformed inline run breaks one paragraph, not the whole reply
--   * code blocks get a background, padding and a language tag
--   * code is verbatim — no escaping, so no way to mangle it
-- RichText survives only inside single paragraphs, where mixing weights in one
-- wrapped label needs it.

local Theme = require(script.Parent:WaitForChild("Theme"))
local Markdown = require(script.Parent:WaitForChild("Markdown"))

local make = Theme.make

local Console = {}
local output: ScrollingFrame = nil :: any

local KIND_COLOR: { [string]: Color3 } = {
	user      = Theme.ACCENT,
	assistant = Theme.TEXT_HI,
	cmd       = Theme.ACCENT,
	error     = Theme.ERR_CLR,
	info      = Theme.TEXT_MED,
	system    = Theme.TEXT_MED,
}
-- No prefix for `user`: those lines are right-aligned now, and a leading arrow
-- reads as a left-margin marker.
local KIND_PREFIX: { [string]: string } = { cmd = "$ " }

-- =============================================================================
-- Mount
-- =============================================================================
function Console.mount(parent: Instance, layoutOrder: number): ScrollingFrame
	output = make("ScrollingFrame", {
		Name = "Output",
		Parent = parent,
		BackgroundColor3 = Theme.BG_DARK,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -64),
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.TEXT_LO,
		LayoutOrder = layoutOrder,
	})
	make("UIListLayout", {
		Parent = output,
		Padding = UDim.new(0, 3),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	make("UIPadding", {
		Parent = output,
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
	})
	return output
end

function Console.scrollToBottom()
	task.defer(function()
		output.CanvasPosition = Vector2.new(0, math.huge)
	end)
end

function Console.clear()
	for _, child in ipairs(output:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- TextEditable stays TRUE. Setting it false is the obvious way to make a
-- read-only box and it does not work: the box stops taking focus at all, and
-- with no focus there is no caret, no selection and nothing for Ctrl+C to copy.
-- So the box is a completely ordinary editable TextBox — which is what makes it
-- reliably selectable — and read-only is enforced by reverting any edit.
--
-- Returns the box and a setter. Content has to go through the setter so the
-- guard knows what the text is supposed to be; assigning .Text directly would
-- be immediately reverted.
local function readOnlyBox(parent: Instance, font: Font, size: number, color: Color3)
	local box = make("TextBox", {
		Parent = parent,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = font,
		TextSize = size,
		TextColor3 = color,
		TextWrapped = true,
		RichText = false,
		MultiLine = true,
		TextEditable = true,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
	})

	local content = ""
	local setting = false
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if setting or box.Text == content then return end
		-- Someone typed. Put it back. Selecting and copying never changes .Text,
		-- so this costs the reader nothing.
		setting = true
		box.Text = content
		setting = false
	end)

	return box, function(text: string)
		content = text
		setting = true
		box.Text = text
		setting = false
	end
end

-- Focus the box and select all of it, so the next Ctrl+C takes the lot.
-- CursorPosition first, then SelectionStart: setting the cursor clears any
-- existing selection, so anchoring afterwards is what actually makes a range.
local function selectAll(box: TextBox)
	box:CaptureFocus()
	box.CursorPosition = #box.Text + 1
	box.SelectionStart = 1
end

-- =============================================================================
-- Plain lines
-- =============================================================================
-- Commands, status and errors are never Markdown, so RichText stays off and the
-- text goes in raw. Nothing to escape means nothing to escape wrongly.
--
-- Selectable, for the same reason code blocks are: this is where tool output
-- lands — grep hits, file listings, error text — and it is exactly the sort of
-- thing you want to pull out of the widget. RichText being off here is what
-- makes that safe; a selection copies the characters you can see, with no markup
-- to leak into it.
function Console.appendLine(text: string, kind: string?): TextBox
	-- Counted BEFORE the box is made, because readOnlyBox parents it on
	-- creation and a count taken afterwards includes the new child. Bubbles
	-- number themselves the same way, so an off-by-one here would let a line and
	-- a bubble share a LayoutOrder and swap places.
	local order = #output:GetChildren() + 1
	local line, setLine = readOnlyBox(
		output,
		(kind == "user") and Theme.SANS or Theme.MONO,
		Theme.TEXT_SIZE,
		KIND_COLOR[kind or ""] or Theme.TEXT_HI
	)
	line.Name = "Line"
	line.LayoutOrder = order

	-- What you typed sits on the right, everything the plugin says on the left.
	-- The console is one long column of monospace and a user turn used to be
	-- just another line in it; side is the cheapest signal there is for "this
	-- one was me". The left inset keeps a long message from spanning the full
	-- width and losing the effect, and the prompt arrow comes off — it reads as
	-- a left-margin marker and looks wrong leading a right-aligned line.
	if kind == "user" then
		line.TextXAlignment = Enum.TextXAlignment.Right
		make("UIPadding", { Parent = line, PaddingLeft = UDim.new(0.22, 0) })
	end

	setLine((KIND_PREFIX[kind or ""] or "") .. text)
	Console.scrollToBottom()
	return line
end

-- =============================================================================
-- Block renderers
-- =============================================================================
-- Each returns the root GuiObject plus a setter, so the reconciler can update a
-- block in place instead of rebuilding it.
type Rendered = { node: GuiObject, set: (Markdown.Block) -> () }

local HEADING_SIZE = { 20, 17, 15, 14, 13, 13 }

local function richLabel(parent: Instance, font: Font, size: number, color: Color3): TextLabel
	return make("TextLabel", {
		Parent = parent,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = font,
		TextSize = size,
		TextColor3 = color,
		TextWrapped = true,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
	})
end

-- richLabel is the RichText one, and it is deliberately NOT selectable. With
-- RichText on, selection indices map to the RAW string — tags included — so
-- copying a bold word would hand you `<b>word</b>`. Blocks that are already
-- verbatim (code, plain lines, the raw-source view) use readOnlyBox instead and
-- are selectable; formatted prose stays a label.
local renderers: { [string]: (Instance) -> Rendered } = {}

renderers.paragraph = function(parent: Instance): Rendered
	local label = richLabel(parent, Theme.SANS, Theme.TEXT_SIZE, Theme.TEXT_HI)
	return {
		node = label,
		set = function(block) label.Text = Markdown.inline(block.text) end,
	}
end

renderers.heading = function(parent: Instance): Rendered
	local label = richLabel(parent, Theme.SANS_BOLD, Theme.TEXT_SIZE, Theme.TEXT_HI)
	return {
		node = label,
		set = function(block)
			label.TextSize = HEADING_SIZE[block.level or 1] or Theme.TEXT_SIZE
			label.Text = Markdown.inline(block.text)
		end,
	}
end

renderers.bullet = function(parent: Instance): Rendered
	local label = richLabel(parent, Theme.SANS, Theme.TEXT_SIZE, Theme.TEXT_HI)
	local padding = make("UIPadding", { Parent = label, PaddingLeft = UDim.new(0, 10) })
	return {
		node = label,
		set = function(block)
			padding.PaddingLeft = UDim.new(0, 10 + (block.level or 0) * 14)
			label.Text = "• " .. Markdown.inline(block.text)
		end,
	}
end

renderers.ordered = function(parent: Instance): Rendered
	local label = richLabel(parent, Theme.SANS, Theme.TEXT_SIZE, Theme.TEXT_HI)
	local padding = make("UIPadding", { Parent = label, PaddingLeft = UDim.new(0, 10) })
	return {
		node = label,
		set = function(block)
			padding.PaddingLeft = UDim.new(0, 10 + (block.level or 0) * 14)
			label.Text = (block.marker or "1") .. ". " .. Markdown.inline(block.text)
		end,
	}
end

renderers.quote = function(parent: Instance): Rendered
	local frame = make("Frame", {
		Parent = parent,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	make("Frame", {
		Parent = frame,
		BackgroundColor3 = Theme.ACCENT_HI,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 2, 1, 0),
	})
	local label = richLabel(frame, Theme.SANS, Theme.TEXT_SIZE, Theme.TEXT_MED)
	label.Size = UDim2.new(1, -12, 0, 0)
	label.Position = UDim2.new(0, 12, 0, 0)
	return {
		node = frame,
		set = function(block) label.Text = Markdown.inline(block.text) end,
	}
end

renderers.code = function(parent: Instance): Rendered
	local frame = make("Frame", {
		Parent = parent,
		BackgroundColor3 = Theme.BG_CODE,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	make("UICorner", { Parent = frame, CornerRadius = UDim.new(0, 5) })
	make("UIListLayout", { Parent = frame, SortOrder = Enum.SortOrder.LayoutOrder })
	make("UIPadding", {
		Parent = frame,
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 8),
	})

	-- The header row exists whether or not the fence named a language, because
	-- it carries the copy button and that is wanted on every block.
	local header = make("Frame", {
		Parent = frame,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
		LayoutOrder = 1,
	})
	local langLabel = make("TextLabel", {
		Parent = header,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -72, 1, 0),
		FontFace = Theme.SANS,
		TextSize = 10,
		TextColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = false,
		Text = "",
	})
	local copyButton = make("TextButton", {
		Parent = header,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 68, 1, 0),
		FontFace = Theme.SANS,
		TextSize = 10,
		TextColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "select all",
		AutoButtonColor = false,
	})

	-- RichText OFF: code is shown byte for byte. No escaping step means no way
	-- for a < or & in someone's source to corrupt the render.
	-- ponytail: long lines wrap instead of scrolling horizontally. A real
	-- horizontal scroll needs a nested ScrollingFrame plus measured text width;
	-- wrapping keeps the code visible, which is the part that matters.
	local body, setBody = readOnlyBox(frame, Theme.MONO, Theme.SMALL_SIZE, Theme.CODE_CLR)
	body.LayoutOrder = 2

	copyButton.MouseButton1Click:Connect(function()
		selectAll(body)
		-- The button cannot copy — nothing in a plugin can. It selects, and then
		-- says what to press. Naming the key beats a "Copy" label that silently
		-- does half of what it claims.
		copyButton.Text = "press Ctrl+C"
		copyButton.TextColor3 = Theme.ACCENT
		task.delay(2.5, function()
			copyButton.Text = "select all"
			copyButton.TextColor3 = Theme.TEXT_LO
		end)
	end)

	return {
		node = frame,
		set = function(block)
			langLabel.Text = block.lang or ""
			setBody(block.text)
		end,
	}
end

-- ponytail: columns split the width evenly and set() rebuilds every cell rather
-- than diffing them. Both are fine because a streaming table only grows for a
-- few frames. Ceiling: a wide table with one long column looks cramped; the
-- upgrade is measuring text with TextService:GetTextBoundsAsync and weighting
-- the columns by their longest cell.
local ALIGN: { [string]: Enum.TextXAlignment } = {
	left = Enum.TextXAlignment.Left,
	center = Enum.TextXAlignment.Center,
	right = Enum.TextXAlignment.Right,
}

renderers.table = function(parent: Instance): Rendered
	local frame = make("Frame", {
		Parent = parent,
		BackgroundColor3 = Theme.BG_CODE,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ClipsDescendants = true,
	})
	make("UICorner", { Parent = frame, CornerRadius = UDim.new(0, 5) })
	make("UIListLayout", { Parent = frame, SortOrder = Enum.SortOrder.LayoutOrder })

	return {
		node = frame,
		set = function(block)
			for _, child in ipairs(frame:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end

			local rows = block.rows or {}
			local align = block.align or {}
			local columns = 0
			for _, row in ipairs(rows) do
				columns = math.max(columns, #row)
			end
			if columns == 0 then return end

			for rowIndex, row in ipairs(rows) do
				local isHeader = rowIndex == 1
				local rowFrame = make("Frame", {
					Parent = frame,
					BackgroundColor3 = isHeader and Theme.BG_INPUT or Theme.BG_CODE,
					BackgroundTransparency = isHeader and 0 or 1,
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					-- Rows and the dividers between them share one layout, so
					-- rows take even slots and dividers the odd one after.
					LayoutOrder = rowIndex * 2,
				})
				-- Horizontal layout: the row's height becomes the tallest cell,
				-- so a wrapped cell doesn't overlap the row below it.
				make("UIListLayout", {
					Parent = rowFrame,
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					VerticalAlignment = Enum.VerticalAlignment.Top,
				})

				for column = 1, columns do
					local cell = make("TextLabel", {
						Parent = rowFrame,
						BackgroundTransparency = 1,
						Size = UDim2.new(1 / columns, 0, 0, 0),
						AutomaticSize = Enum.AutomaticSize.Y,
						FontFace = isHeader and Theme.SANS_BOLD or Theme.SANS,
						TextSize = Theme.SMALL_SIZE,
						TextColor3 = isHeader and Theme.TEXT_HI or Theme.TEXT_MED,
						TextWrapped = true,
						RichText = true,
						TextXAlignment = ALIGN[align[column] or "left"],
						TextYAlignment = Enum.TextYAlignment.Top,
						Text = Markdown.inline(row[column] or ""),
						LayoutOrder = column,
					})
					make("UIPadding", {
						Parent = cell,
						PaddingLeft = UDim.new(0, 8),
						PaddingRight = UDim.new(0, 8),
						PaddingTop = UDim.new(0, 5),
						PaddingBottom = UDim.new(0, 5),
					})
				end

				if rowIndex < #rows then
					make("Frame", {
						Parent = frame,
						BackgroundColor3 = Theme.BORDER,
						BackgroundTransparency = isHeader and 0 or 0.5,
						BorderSizePixel = 0,
						Size = UDim2.new(1, 0, 0, 1),
						LayoutOrder = rowIndex * 2 + 1,
					})
				end
			end
		end,
	}
end

renderers.rule = function(parent: Instance): Rendered
	local frame = make("Frame", {
		Parent = parent,
		BackgroundColor3 = Theme.BORDER,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	})
	return { node = frame, set = function() end }
end

renderers.blank = function(parent: Instance): Rendered
	local frame = make("Frame", {
		Parent = parent,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 5),
	})
	return { node = frame, set = function() end }
end

-- =============================================================================
-- Streaming assistant bubble
-- =============================================================================
export type Thinking = {
	append: (string) -> (),
	finish: () -> (),
	destroy: () -> (),
}

export type Bubble = {
	setText: (string) -> (),
	setError: (string) -> (),
	thinking: () -> Thinking,
	finishThinking: () -> (),
}

-- ponytail: re-parses the accumulated reply on each render, so an n-character
-- reply does O(n²) parsing. Throttled to ~20 fps below, and reconciliation means
-- only changed blocks touch the DataModel. Ceiling is roughly a 10k-character
-- reply; past that, parse only the tail after the last completed block.
local RENDER_INTERVAL = 0.05

function Console.createBubble(): Bubble
	local container = make("Frame", {
		Name = "Assistant",
		Parent = output,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = #output:GetChildren() + 1,
	})
	make("UIListLayout", {
		Parent = container,
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	local rendered: { Rendered & { kind: string } } = {}
	-- Set while the raw-markdown view is up, so a block drawn mid-stream does
	-- not pop back into view behind it.
	local showingSource = false

	-- Thinking lives INSIDE the bubble at LayoutOrder 0, above the answer blocks
	-- (which start at 1). Creating it as a separate top-level child put it after
	-- the bubble in the output list, so reasoning rendered BELOW the reply it
	-- produced. Lazy, so a turn with no thinking shows no empty block.
	local thinkingBlock: Thinking? = nil
	local function ensureThinking(): Thinking
		if not thinkingBlock then
			thinkingBlock = Console.createThinking(container, 0)
		end
		return thinkingBlock :: Thinking
	end

	-- Reconcile against the previous render: reuse a slot when its kind still
	-- matches, otherwise drop it and everything after. During streaming only the
	-- last block usually changes, so this is a handful of property writes.
	local function draw(blocks: { Markdown.Block })
		for i, block in ipairs(blocks) do
			local slot = rendered[i]
			if slot and slot.kind ~= block.kind then
				for j = #rendered, i, -1 do
					rendered[j].node:Destroy()
					rendered[j] = nil
				end
				slot = nil
			end
			if not slot then
				local built = renderers[block.kind](container)
				slot = { node = built.node, set = built.set, kind = block.kind }
				rendered[i] = slot
			end
			slot.node.LayoutOrder = i
			slot.node.Visible = not showingSource
			slot.set(block)
		end
		for j = #rendered, #blocks + 1, -1 do
			rendered[j].node:Destroy()
			rendered[j] = nil
		end
		Console.scrollToBottom()
	end

	-- Selection cannot cross widgets in Roblox — each TextBox is its own scope,
	-- so there is no dragging from one paragraph into the next the way a text
	-- editor lets you. This is the way around that: one toggle that swaps the
	-- whole rendered reply for the raw markdown it was built from, in a single
	-- selectable box. Raw markdown is also the more useful thing to paste back
	-- than the rendered text would be.
	local sourceToggle = make("TextButton", {
		Parent = container,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 60, 0, 14),
		FontFace = Theme.SANS,
		TextSize = 10,
		TextColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "⧉ raw",
		AutoButtonColor = false,
		Visible = false,
		LayoutOrder = 1000,   -- below the answer; blocks number up from 1
	})
	local sourceBox, setSource = readOnlyBox(container, Theme.MONO, Theme.SMALL_SIZE, Theme.TEXT_MED)
	sourceBox.Visible = false
	sourceBox.LayoutOrder = 1001

	sourceToggle.MouseButton1Click:Connect(function()
		showingSource = not showingSource
		for _, slot in ipairs(rendered) do
			slot.node.Visible = not showingSource
		end
		sourceBox.Visible = showingSource
		sourceToggle.Text = showingSource and "⧉ rendered" or "⧉ raw"
		if showingSource then
			selectAll(sourceBox)
		end
		Console.scrollToBottom()
	end)

	local lastRender = 0
	local pending: string? = nil
	local scheduled = false

	local function render(md: string)
		draw(Markdown.parse(md))
		setSource(md)
		sourceToggle.Visible = md ~= ""
		lastRender = os.clock()
	end

	Console.scrollToBottom()
	return {
		thinking = ensureThinking,
		finishThinking = function()
			if thinkingBlock then (thinkingBlock :: Thinking).finish() end
		end,
		setText = function(md: string)
			pending = md
			if os.clock() - lastRender >= RENDER_INTERVAL then
				render(md)
			elseif not scheduled then
				-- The trailing flush matters: without it a reply that finishes
				-- inside the throttle window loses its last tokens.
				scheduled = true
				task.delay(RENDER_INTERVAL, function()
					scheduled = false
					if pending then render(pending :: string) end
				end)
			end
		end,
		setError = function(message: string)
			pending = nil
			for j = #rendered, 1, -1 do
				rendered[j].node:Destroy()
				rendered[j] = nil
			end
			local label = make("TextLabel", {
				Parent = container,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				FontFace = Theme.MONO,
				TextSize = Theme.TEXT_SIZE,
				TextColor3 = Theme.ERR_CLR,
				TextWrapped = true,
				RichText = false,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = "(error: " .. message .. ")",
			})
			label.Parent = container
			Console.scrollToBottom()
		end,
	}
end

-- =============================================================================
-- Collapsible thinking block
-- =============================================================================
function Console.createThinking(parent: Instance?, layoutOrder: number?): Thinking
	local host = parent or output
	local container = make("Frame", {
		Name = "ThinkingBlock",
		Parent = host,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder or (#host:GetChildren() + 1),
	})
	make("UIListLayout", { Parent = container, SortOrder = Enum.SortOrder.LayoutOrder })

	local header = make("TextButton", {
		Parent = container,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		FontFace = Theme.SANS,
		TextSize = Theme.SMALL_SIZE,
		TextColor3 = Theme.THINK_CLR,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "▶ thinking…",
		AutoButtonColor = false,
		LayoutOrder = 1,
	})

	local body = make("TextLabel", {
		Parent = container,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -12, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = Theme.SANS,
		TextSize = Theme.SMALL_SIZE,
		TextColor3 = Theme.TEXT_MED,
		TextWrapped = true,
		RichText = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Visible = false,
		LayoutOrder = 2,
	})
	make("UIPadding", { Parent = body, PaddingLeft = UDim.new(0, 12) })

	local expanded = false
	local finished = false
	header.MouseButton1Click:Connect(function()
		expanded = not expanded
		body.Visible = expanded
		header.Text = (expanded and "▼ " or "▶ ") .. (finished and "thinking" or "thinking…")
		Console.scrollToBottom()
	end)

	local text = ""
	Console.scrollToBottom()
	return {
		append = function(delta: string)
			text ..= delta
			body.Text = text
			if expanded then Console.scrollToBottom() end
		end,
		finish = function()
			finished = true
			header.Text = (expanded and "▼ " or "▶ ") .. "thinking"
		end,
		destroy = function()
			container:Destroy()
		end,
	}
end

-- =============================================================================
-- Tool calls
-- =============================================================================
local TOOL_PREVIEW_LINES = 5

-- write/edit carry whole files in `content` and `old`/`new`. Printing those raw
-- would bury the console under the very source Claude just wrote.
local MAX_ARG_CHARS = 60

local function summarise(value: any): string
	local text = tostring(value)
	local firstLine = text:match("^[^\n]*") or text
	local truncated = #firstLine < #text or #firstLine > MAX_ARG_CHARS
	if #firstLine > MAX_ARG_CHARS then
		firstLine = firstLine:sub(1, MAX_ARG_CHARS)
	end
	return truncated and (firstLine .. "…") or firstLine
end

function Console.appendToolCall(toolName: string, input: { [string]: any }, result: string?)
	local parts: { string } = {}
	for k, v in pairs(input) do
		table.insert(parts, tostring(k) .. "=" .. summarise(v))
	end
	table.sort(parts)
	Console.appendLine(string.format("[%s: %s]", toolName, table.concat(parts, " ")), "cmd")

	if not result then return end
	local shown = 0
	for line in result:gmatch("[^\n]*") do
		if shown >= TOOL_PREVIEW_LINES then
			Console.appendLine("  …", "info")
			break
		end
		if line ~= "" then
			Console.appendLine("  " .. line, "info")
			shown += 1
		end
	end
end

return Console
