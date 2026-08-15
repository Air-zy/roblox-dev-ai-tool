--!strict
-- Console.luau: the scrolling output area.
--
-- Assistant replies are rendered as real GUI objects, one per Markdown block,
-- rather than as one big RichText string. That buys three things the string
-- approach could not have:
--   * a malformed inline run breaks one paragraph, not the whole reply
--   * code blocks get a background, padding and a language tag
--   * code is verbatim, no escaping, so no way to mangle it
-- RichText survives only inside single paragraphs, where mixing weights in one
-- wrapped label needs it.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local Markdown = require(script.Parent:WaitForChild("Markdown"))

local make = Theme.make

local Console = {}
local output: ScrollingFrame = nil :: any
-- The "Working..." row, see Console.setWorking.
local workingRow: TextLabel = nil :: any

-- Sticky bottom. ScrollingFrame has no bottom-pin and no scroll method, the
-- whole API is CanvasPosition and two read-only measurements, so following the
-- bottom is bookkeeping, and the only question is where to do it from.
--
-- Not from property signals, which is what the two earlier attempts here got
-- wrong in opposite directions. Writing CanvasPosition right after adding
-- content landed short, because AutomaticCanvasSize recomputes the canvas a step
-- LATER and the write was clamped against the old, shorter one. Writing it from
-- the AbsoluteCanvasSize signal instead had the same disease one layer down: the
-- signal says the size CHANGED, not that layout has settled, and the docs do not
-- say when the clamp bound is recomputed relative to it, so the view still
-- crept further behind the longer a reply ran.
--
-- Everything therefore runs once per frame on Heartbeat, where the numbers are
-- settled and no ordering has to be assumed.
--
-- The other half is telling the reader's scroll apart from the engine's own
-- clamp, so that reading back through a reply is not fought while a canvas
-- shrink: the Working row hiding at the end of a turn, a thinking block
-- collapsing, a re-render dropping trailing blocks, is not mistaken for one.
-- That needs no input events, which is good, because a ScrollingFrame handles
-- the wheel and its own scrollbar internally and is not obliged to surface
-- either as an InputObject. The engine only ever moves the position UP, and only
-- as far as a shrunken canvas forces; anything above that is the reader.
local STICK_SLOP = 16
local stickToBottom = true

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

-- Mount
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

	-- Made once here and hidden, rather than appended and destroyed each turn:
	-- every appender numbers its block from #output:GetChildren(), so a child that
	-- comes and goes makes that count shrink and lets a later block reuse a
	-- LayoutOrder that is still on screen. A permanent child is just another
	-- constant in the count, like the layout and padding objects. UIListLayout
	-- skips invisible children, so it takes no space while idle.
	--
	-- LayoutOrder is the int32 ceiling so the row stays last however long the
	-- conversation runs.
	workingRow = make("TextLabel", {
		Name = "Working",
		Parent = output,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		FontFace = Theme.MONO,
		TextSize = Theme.TEXT_SIZE,
		TextColor3 = Theme.TEXT_MED,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Visible = false,
		LayoutOrder = 2147483647,
	})

	-- One connection does the whole thing: decide, then pin, once per frame with
	-- settled numbers. maxY is the bottom of the scroll range, the only fact the
	-- engine gives us to work with.
	local lastPos = 0
	RunService.Heartbeat:Connect(function()
		local maxY = math.max(output.AbsoluteCanvasSize.Y - output.AbsoluteWindowSize.Y, 0)
		local pos = output.CanvasPosition.Y
		-- Where the view would sit if nobody but the engine had touched it: it only
		-- ever moves the position UP, and only as far as a shrunken canvas forces.
		local clamped = math.min(lastPos, maxY)
		if pos < clamped - 1 then
			-- Higher than a clamp can account for, so the reader put it there.
			stickToBottom = false
		elseif pos >= maxY - STICK_SLOP then
			-- At the bottom, however it got there, scrolled back down, or the canvas
			-- shrank out from under a position that is now the bottom.
			stickToBottom = true
		end
		if stickToBottom and pos < maxY then
			output.CanvasPosition = Vector2.new(0, maxY)
			pos = maxY
		end
		lastPos = pos
	end)
	return output
end

-- `force` re-arms following even if the reader had scrolled up, for things they
-- just did themselves, like sending a message.
function Console.scrollToBottom(force: boolean?)
	if force then stickToBottom = true end
	if not stickToBottom then return end
	-- Deliberately math.huge rather than the measured canvas: the engine clamps,
	-- and the measurement can still be one step stale here.
	output.CanvasPosition = Vector2.new(0, math.huge)
end

function Console.scrollToTop()
	stickToBottom = false
	output.CanvasPosition = Vector2.new(0, 0)
end

function Console.clear()
	stickToBottom = true  -- an empty console is at its bottom by definition
	for _, child in ipairs(output:GetChildren()) do
		if child:IsA("GuiObject") and child ~= workingRow then
			child:Destroy()
		end
	end
end

-- TextEditable stays TRUE. Setting it false is the obvious way to make a
-- read-only box and it does not work: the box stops taking focus at all, and
-- with no focus there is no caret, no selection and nothing for Ctrl+C to copy.
-- So the box is a completely ordinary editable TextBox, which is what makes it
-- reliably selectable, and read-only is enforced by reverting any edit.
--
-- Returns the box and a setter. Content has to go through the setter so the
-- guard knows what the text is supposed to be; assigning .Text directly would
-- be immediately reverted.
-- Roblox truncates a TextLabel or TextBox `.Text` at 16 KiB. Silently, with no
-- warning and no property saying it happened, and it is documented nowhere but
-- the devforum. The failure therefore does not look like a display limit: a long
-- thinking drawer or a large code block simply stops mid-word, which reads as the
-- model having given up rather than the label having.
--
-- Every unbounded assignment goes through here or through the cap in
-- renderDetail. A new one is a new instance of the same silent bug.
local ENGINE_TEXT_LIMIT = 16384

local function fitText(text: string): string
	if #text <= ENGINE_TEXT_LIMIT then return text end
	-- Reserve is generous because the note has to fit INSIDE the limit; a note
	-- appended past it is the one part guaranteed to be cut off.
	local keep = ENGINE_TEXT_LIMIT - 64
	return text:sub(1, keep)
		.. string.format("\n… %d more characters, past what Roblox will render",
			#text - keep)
end

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
		-- Fitted BEFORE it is stored, not just before it is shown: `content` is
		-- what the typing guard above puts back, so storing the unfitted string
		-- would make every keystroke restore a value the box can never hold, and
		-- the two would never compare equal again.
		content = fitText(text)
		setting = true
		box.Text = content
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

-- Plain lines
-- Commands, status and errors are never Markdown, so RichText stays off and the
-- text goes in raw. Nothing to escape means nothing to escape wrongly.
--
-- Selectable, for the same reason code blocks are: this is where tool output
-- lands: grep hits, file listings, error text, and it is exactly the sort of
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
	-- width and losing the effect, and the prompt arrow comes off, it reads as
	-- a left-margin marker and looks wrong leading a right-aligned line.
	if kind == "user" then
		line.TextXAlignment = Enum.TextXAlignment.Right
		make("UIPadding", { Parent = line, PaddingLeft = UDim.new(0.22, 0) })
	end

	setLine((KIND_PREFIX[kind or ""] or "") .. text)
	Console.scrollToBottom(kind == "user")
	return line
end

-- A clickable line. Only user is the "load earlier" control a replay puts at the
-- top of a truncated session, so it is a bare TextButton rather than anything
-- with a hit area of its own.
function Console.appendLink(text: string, onClick: () -> ()): TextButton
	local button = make("TextButton", {
		Name = "Link",
		Parent = output,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		FontFace = Theme.MONO,
		TextSize = Theme.TEXT_SIZE,
		TextColor3 = Theme.ACCENT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		AutoButtonColor = false,
		LayoutOrder = #output:GetChildren() + 1,
	})
	button.MouseButton1Click:Connect(onClick)
	return button
end

-- Block renderers
-- Each returns the root GuiObject plus a setter, so the reconciler can update a
-- block in place instead of rebuilding it.
type Rendered = { node: GuiObject, set: (Markdown.Block) -> () }

local HEADING_SIZE = { 22, 19, 17, 16, 15, 15 }

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
-- RichText on, selection indices map to the RAW string, tags included, so
-- copying a bold word would hand you `<b>word</b>`. Blocks that are already
-- verbatim (code, plain lines, tool detail) use readOnlyBox instead and
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
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 1,
	})
	local langLabel = make("TextLabel", {
		Parent = header,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -72, 1, 0),
		FontFace = Theme.SANS,
		TextSize = 12,
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
		TextSize = 12,
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
		-- The button cannot copy, nothing in a plugin can. It selects, and then
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

-- Streaming assistant bubble
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
-- reply does O(n^2) parsing. Throttled to ~20 fps below, and reconciliation means
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
			slot.set(block)
		end
		for j = #rendered, #blocks + 1, -1 do
			rendered[j].node:Destroy()
			rendered[j] = nil
		end
		Console.scrollToBottom()
	end

	-- No raw-markdown toggle here. It bought whole-reply selection (Roblox
	-- selection cannot cross widgets, so paragraphs can't be dragged through),
	-- but a button under every single reply was a worse cost. Code blocks keep
	-- their own "select all", which is what actually gets copied.

	local lastRender = 0
	local pending: string? = nil
	local scheduled = false

	local function render(md: string)
		draw(Markdown.parse(md))
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

-- Spinner
local SPINNER = { "/", "-", "\\", "|" }
local SPINNER_INTERVAL = 0.12

-- One animation for everything that is still running: the thinking header, a
-- tool call waiting on its result, and the input placeholder. `render` gets the
-- current frame and does whatever that caller's text needs. `alive` stops the
-- loop when its Instance is destroyed, for callers that never get a stop() call
-- (Console.clear destroys blocks out from under them).
function Console.spin(render: (string) -> (), alive: Instance?): () -> ()
	local i, running = 1, true
	render(SPINNER[i])
	task.spawn(function()
		while running and (alive == nil or alive.Parent) do
			task.wait(SPINNER_INTERVAL)
			if not running then break end   -- stop() may have landed during the wait
			i = i % #SPINNER + 1
			render(SPINNER[i])
		end
	end)
	return function()
		running = false
	end
end

-- Sits below everything in the console for as long as a turn is running, which
-- is where the next block is about to appear. It covers the gap between sending
-- and the first token, thinking blocks and tool calls carry their own spinners
-- once they exist, but until then the console is silent.
local stopWorking: (() -> ())? = nil
function Console.setWorking(on: boolean)
	if stopWorking then
		stopWorking()
		stopWorking = nil
	end
	workingRow.Visible = on
	if on then
		stopWorking = Console.spin(function(frame: string)
			workingRow.Text = frame .. " Working…"
		end)
		Console.scrollToBottom()
	end
end

-- Collapsible thinking block
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

	-- MONO, matching a tool call's header and detail box. The two are the same
	-- affordance: a collapsed row you click to expand, and they were already the
	-- same TextSize; the only thing making them look different was BuilderSans
	-- next to RobotoMono at the same nominal size.
	local header = make("TextButton", {
		Parent = container,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		FontFace = Theme.MONO,
		TextSize = Theme.SMALL_SIZE,
		TextColor3 = Theme.THINK_CLR,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "▶ thinking",
		AutoButtonColor = false,
		LayoutOrder = 1,
	})

	local body = make("TextLabel", {
		Parent = container,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -12, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		FontFace = Theme.MONO,
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
	local frame = SPINNER[1]
	local function render()
		header.Text = (expanded and "▼ " or "▶ ") .. "thinking"
			.. (finished and "" or (" " .. frame))
	end
	local stopSpin = Console.spin(function(f)
		frame = f
		render()
	end, container)

	header.MouseButton1Click:Connect(function()
		expanded = not expanded
		body.Visible = expanded
		render()
		Console.scrollToBottom()
	end)

	local text = ""
	-- Latched at the point the label stops accepting more. A long thought runs to
	-- tens of thousands of characters, and reassigning a 16 KiB string on every
	-- delta once it can no longer change anything is pure cost, so past the limit
	-- this stops writing to the label entirely.
	--
	-- The note carries no count, deliberately. Thinking is still streaming when
	-- this fires, so any number written here would be wrong a moment later, and a
	-- stale number is worse than none: it reads as the total.
	local capped = false
	Console.scrollToBottom()
	return {
		append = function(delta: string)
			text ..= delta
			if not capped then
				if #text > ENGINE_TEXT_LIMIT then
					capped = true
					body.Text = text:sub(1, ENGINE_TEXT_LIMIT - 64)
						.. "\n… still thinking, past what Roblox will render"
				else
					body.Text = text
				end
			end
			if expanded then Console.scrollToBottom() end
		end,
		finish = function()
			finished = true
			stopSpin()
			render()
		end,
		destroy = function()
			stopSpin()
			container:Destroy()
		end,
	}
end

-- Tool calls
-- write/edit carry whole files in `content` and `old`/`new`. Printing those raw
-- would bury the console under the very source Claude just wrote, so the header
-- gets a one-line summary and the full text lives in the expandable body.
local MAX_ARG_CHARS = 60
-- A read of a large file comes back as one string. Past this the body is a wall
-- nobody reads, and every character is a TextBox the DataModel has to lay out.
local MAX_DETAIL_CHARS = 4000

local function summarise(value: any): string
	local text = tostring(value)
	local firstLine = text:match("^[^\n]*") or text
	local truncated = #firstLine < #text or #firstLine > MAX_ARG_CHARS
	if #firstLine > MAX_ARG_CHARS then
		firstLine = firstLine:sub(1, MAX_ARG_CHARS)
	end
	return truncated and (firstLine .. "…") or firstLine
end

-- tostring on a table gives "table: 0x...", and multiedit's `edits` is a table.
local function verbatim(value: any): string
	if type(value) == "string" then return value end
	local encoded
	local ok = pcall(function() encoded = HttpService:JSONEncode(value) end)
	return (ok and encoded) or tostring(value)
end

-- Collapsed by default, same shape as the thinking block: the header carries the
-- tool name and shortened arguments, and clicking it reveals the untruncated
-- input and result.
--
-- `result` may be omitted and supplied later through the returned setResult:
-- server tools (web search) are run by Anthropic, so their call and their result
-- arrive as two separate stream blocks and the header has to go up before the
-- results exist, or the user watches a silent console while a search runs.
-- `isError` only recolours the header; the body is the same expandable detail,
-- which is the point, a failed call is exactly the one you want to open.
--
-- `input` may likewise be empty at first and filled in later through setInput.
-- A tool_use block announces its name and id the moment the model starts writing
-- the call, but its arguments stream in afterwards, a whole file, for a `write`
--, so the header goes up argument-less rather than leaving the console silent
-- for the seconds that takes.
function Console.appendToolCall(toolName: string, input: { [string]: any }, result: string?, isError: boolean?)
	local label = ""
	local detail: { string } = {}
	-- Rebuilt rather than appended to: setInput replaces the arguments outright,
	-- it never adds to them.
	local function readInput(from: { [string]: any })
		local keys: { string } = {}
		for k in pairs(from) do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)

		local summary: { string } = {}
		detail = {}
		for _, k in ipairs(keys) do
			table.insert(summary, k .. "=" .. summarise(from[k]))
			table.insert(detail, k .. ": " .. verbatim(from[k]))
		end
		label = if #summary > 0
			then string.format("[%s: %s]", toolName, table.concat(summary, " "))
			else string.format("[%s]", toolName)
	end
	readInput(input)

	local order = #output:GetChildren() + 1
	local container = make("Frame", {
		Name = "ToolCall",
		Parent = output,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	})
	make("UIListLayout", { Parent = container, SortOrder = Enum.SortOrder.LayoutOrder })

	local header = make("TextButton", {
		Parent = container,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		FontFace = Theme.MONO,
		TextSize = Theme.SMALL_SIZE,
		TextColor3 = isError and Theme.ERR_CLR or Theme.ACCENT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "▶ " .. label,
		AutoButtonColor = false,
		LayoutOrder = 1,
	})

	local detailBox, setDetail = readOnlyBox(container, Theme.MONO, Theme.SMALL_SIZE, Theme.TEXT_MED)
	detailBox.Visible = false
	detailBox.LayoutOrder = 2
	make("UIPadding", { Parent = detailBox, PaddingLeft = UDim.new(0, 12) })

	-- The raw argument JSON as it streams, before there is anything parsed to
	-- show. Kept separately from `detail` because it is replaced wholesale the
	-- moment setInput lands, rather than merged with it.
	--
	-- Two counters, and the split is the point: `streamed` stops growing at the
	-- cap so re-rendering stays O(cap) per fragment instead of O(n), while
	-- `streamedLen` keeps counting so the header can report the real size. A
	-- `write` arrives as thousands of fragments, and concatenating the whole
	-- buffer on each one is how a progress display becomes the slow part.
	local streamed = ""
	local streamedLen = 0

	local function renderDetail(res: string?)
		local lines = table.clone(detail)
		if #lines == 0 and streamed ~= "" then
			lines = { streamed }
		end
		if res then
			table.insert(lines, "")
			table.insert(lines, res)
		end
		local body = table.concat(lines, "\n")
		if #body > MAX_DETAIL_CHARS then
			body = body:sub(1, MAX_DETAIL_CHARS)
				.. string.format("\n… %d more characters", #body - MAX_DETAIL_CHARS)
		end
		setDetail(body)
	end
	renderDetail(result)

	-- No result yet means the call is still running, so the header spins the same
	-- way the thinking header does until setResult lands.
	local expanded = false
	-- Declared above the handlers that close over it, not beside setResult where
	-- it is written: a `local` introduced later is a different binding, and the
	-- click handler would have captured a global nil instead.
	local lastResult = result
	local pending = result == nil
	local frame = SPINNER[1]
	local function renderHeader()
		-- While the arguments are still streaming there is nothing to summarise,
		-- so the size stands in for them. It is the only thing on screen that
		-- distinguishes a large `write` making progress from a call that has
		-- stalled, which is the whole reason the spinner alone was not enough.
		--
		-- It survives the call finishing, which it did not at first. Clearing it
		-- on setInput meant the number only existed while the arguments were in
		-- flight, so on a fast call it flashed for a frame and on a slow one you
		-- had to be looking at the right moment — and afterwards there was no way
		-- to tell whether it had ever appeared. A finished `write` saying how big
		-- it was is worth more than a tidier header.
		local size = if streamedLen > 0
			then string.format(" %.1fk", streamedLen / 1000)
			else ""
		header.Text = (expanded and "▼ " or "▶ ") .. label .. size
			.. (pending and (" " .. frame) or "")
	end
	local stopSpin: (() -> ())? = nil
	if pending then
		stopSpin = Console.spin(function(f)
			frame = f
			renderHeader()
		end, container)
	end

	header.MouseButton1Click:Connect(function()
		expanded = not expanded
		detailBox.Visible = expanded
		-- Re-rendered on open because appendInput skips the render while the block
		-- is closed. Without this, expanding a call mid-stream showed whatever was
		-- there when it was last open, which for a `write` is nothing at all.
		if expanded then renderDetail(lastResult) end
		renderHeader()
		Console.scrollToBottom()
	end)

	Console.scrollToBottom()
	return {
		-- The arguments, once the streamed input has finished and parsed. The
		-- result is re-rendered with them because the detail body is one string
		-- holding both.
		setInput = function(from: { [string]: any })
			readInput(from)
			-- The parsed arguments supersede the raw stream, and dropping it here
			-- is what lets renderDetail prefer `detail` without a mode flag.
			-- streamedLen deliberately survives: it is what the header reports,
			-- and a call that has finished still had a size.
			streamed = ""
			renderHeader()
			renderDetail(lastResult)
		end,
		-- A fragment of the argument JSON, exactly as it came off the wire. Only
		-- reaches here because tools set eager_input_streaming; without it the API
		-- holds the whole parameter back and there is nothing to append.
		--
		-- Renders only while the block is open. A collapsed block still counts the
		-- bytes for the header, so the common case of a long `write` nobody has
		-- expanded costs one concat and one string.format per fragment.
		appendInput = function(fragment: string)
			streamedLen += #fragment
			if #streamed < MAX_DETAIL_CHARS then
				streamed ..= fragment
			end
			renderHeader()
			if expanded then
				renderDetail(lastResult)
				Console.scrollToBottom()
			end
		end,
		-- `failed` recolours the header the way the isError argument does at
		-- creation, for a call that only turns out to be a failure once its
		-- result exists.
		setResult = function(res: string, failed: boolean?)
			lastResult = res
			pending = false
			if stopSpin then stopSpin() end
			if failed then header.TextColor3 = Theme.ERR_CLR end
			renderHeader()
			renderDetail(res)
			if expanded then Console.scrollToBottom() end
		end,
		-- Stops the spinner without a result, for a call whose result is never
		-- coming: the request errored or was cancelled while it was in flight.
		finish = function()
			pending = false
			if stopSpin then stopSpin() end
			renderHeader()
		end,
	}
end

return Console
