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
-- Where NEW blocks are parented. Normally `output` itself; while a session is
-- being peeked at mid-turn it is a detached holder, so the turn that is still
-- streaming keeps rendering into its own blocks off screen instead of into the
-- conversation the reader has opened on top of it. See Console.detach.
--
-- The blocks are MOVED into the holder, not copied: the running turn holds
-- references to them and goes on writing into the same Instances.
local sink: Instance = nil :: any

-- LayoutOrder comes from a counter, not from counting the parent's children.
-- Counting was wrong on both sides of a peek: the output frame also holds a
-- UIListLayout, a UIPadding and the Working row, and the detached holder holds
-- none of the three, so a block appended while the reader was away was numbered
-- three below where it belonged and sorted itself into the middle of the
-- conversation on the way back.
--
-- Never reset. It only has to increase; the Working row sits at the int32
-- ceiling so it stays last however long this runs.
local nextOrder = 0
-- The "Working..." row, see Console.setWorking.
local workingRow: TextLabel = nil :: any
-- The one per-frame connection, kept so Console.unload can drop it.
local heartbeat: RBXScriptConnection? = nil

-- How many blocks stay DRAWN.
--
-- The conversation is not trimmed by any of this — Agent and Sessions still hold
-- every message, and Claude still sees all of it. This caps what the console
-- holds, which is a different thing and the one that costs.
--
-- Every block is an AutomaticSize TextBox with TextWrapped, inside a
-- UIListLayout, inside a ScrollingFrame with AutomaticCanvasSize: the canvas
-- height is a sum over every child and each child's height is a text
-- measurement, so a width change re-measures all of them and a canvas
-- invalidation re-sums all of them. Uncapped, the cost of every layout pass grew
-- with how long you had been talking — which is why opening a panel got slower
-- the further into a session you were, and why restarting fixed it: a REPLAY
-- only ever draws REPLAY_MESSAGES worth of blocks and the live path had no
-- equivalent.
--
-- A guess, and the knob to turn. It wants to be well above what one replay
-- draws, so reopening a session and carrying on does not immediately start
-- dropping what was just restored, and low enough that the ceiling is flat.
-- Measure a freeze in the MicroProfiler before moving it.
local MAX_BLOCKS = 150
-- The most Instances one append is allowed to destroy. See the use below.
local TRIM_BATCH = 8
-- False while a replay is deliberately drawing more than the cap. See
-- Console.uncapped.
local capping = true

-- Destroy the oldest drawn block once there are more than MAX_BLOCKS. A few per
-- new block, so this is amortised rather than a stall the first time the cap is
-- crossed.
--
-- Nothing is lost that cannot come back: Console.jumpToMessage already answers
-- false for a message that is not drawn, and Find's caller already redraws a
-- wider window when it does. That path does not care whether the block went
-- missing because a replay never drew it or because this destroyed it.
--
-- Read off the parent rather than a registry, for the reason the anchors are:
-- the blocks already ARE the record of what is on screen, and a side list would
-- have to be kept in step with every clear, every peek and every re-replay.
--
-- Called BEFORE the block it is making room for exists, so the real ceiling is
-- MAX_BLOCKS + 1. The slack is one block, which is as tight as it gets without
-- trimming after the fact and paying a second pass.
local function trimBlocks()
	if not capping then
		return
	end
	local blocks: { GuiObject } = {}
	for _, child in ipairs(sink:GetChildren()) do
		-- UIListLayout and UIPadding are not GuiObjects, so they are already out;
		-- the Working row is one and has to be named.
		if child:IsA("GuiObject") and child ~= workingRow then
			blocks[#blocks + 1] = child
		end
	end
	if #blocks <= MAX_BLOCKS then
		return
	end
	-- By LayoutOrder, not by position: GetChildren is insertion order, and a peek
	-- re-parents blocks, so insertion order is not age once one has happened.
	table.sort(blocks, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	-- At most a handful per append, so the amortisation above holds even coming
	-- back from an uncapped replay: paging a long session in and then typing
	-- would otherwise destroy hundreds of Instances on one frame, which is the
	-- stall this whole thing exists to remove. It converges over the next few
	-- appends instead.
	local over = math.min(#blocks - MAX_BLOCKS, TRIM_BATCH)
	for index = 1, over do
		blocks[index]:Destroy()
	end
end

-- Draw without the cap, for a redraw whose SIZE is already someone's decision.
--
-- Sessions pages history in by widening `shown` and replaying, and Find reaches
-- a message by widening it far enough to include that message. Both then draw
-- more blocks than the cap on purpose, and trimming underneath them would eat
-- the oldest — which is exactly the part being paged in, and for Find is exactly
-- the message being jumped to. The replay has its own cap in `shown`; this one
-- is only ever about unbounded LIVE growth.
--
-- The freeze a big page-back costs is then one the reader asked for, which is
-- the same trade Sessions already documents for redrawing rather than
-- prepending.
function Console.uncapped(draw: () -> ())
	local previous = capping
	capping = false
	local ok, err = pcall(draw)
	capping = previous
	if not ok then error(err, 0) end
end

-- The cap rides here because every new top-level block passes through this and
-- nothing else does — appendLine, appendLink, the reply bubble, a standalone
-- thinking block and a tool call, all of them and only them. An appender that
-- forgot to call a trim() of its own is exactly how this comes back.
local function takeOrder(): number
	trimBlocks()
	nextOrder += 1
	return nextOrder
end

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
	-- one permanent Instance is less to get wrong than one that comes and goes,
	-- and UIListLayout skips invisible children, so it takes no space while idle.
	-- It also has to stay OUT of the holder a peek detaches, since a running turn
	-- is exactly when it should still be on screen.
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
	-- HELD so it can be dropped again. Heartbeat lives on RunService, which
	-- outlives the plugin, so this goes on running once per frame after an
	-- unload — against an orphaned `output` it also keeps alive. Studio reloads a
	-- plugin whenever its file is rewritten, so without Console.unload the
	-- handlers accumulate one per rebuild and only a Studio restart clears them.
	heartbeat = RunService.Heartbeat:Connect(function()
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
	sink = output
	return output
end

-- Drop the per-frame connection. Called from plugin.Unloading.
function Console.unload()
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

-- `force` re-arms following even if the reader had scrolled up, for things they
-- just did themselves, like sending a message.
function Console.scrollToBottom(force: boolean?)
	-- A detached turn is drawing off screen. Following it would drag the session
	-- the reader is peeking at down to a bottom that is not theirs.
	if sink ~= output then return end
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

-- Clears what is ON SCREEN, which during a peek is the session being previewed
-- and not the turn still running behind it.
function Console.clear()
	stickToBottom = true  -- an empty console is at its bottom by definition
	for _, child in ipairs(output:GetChildren()) do
		if child:IsA("GuiObject") and child ~= workingRow then
			child:Destroy()
		end
	end
end

-- Jumping to a message
-- Anchors are attributes on the blocks themselves rather than a registry: the
-- blocks already ARE the record of what is on screen, and a side table would
-- have to be kept in step with every clear, every peek and every re-replay.
local MESSAGE_ATTR = "msg"
local FLASH_SECONDS = 1.2
local messageIndex = 0

-- Everything appended from here on belongs to message `index` of the
-- conversation. 0 for anything that belongs to no message: banners, errors, the
-- "load earlier" link.
function Console.setMessage(index: number)
	messageIndex = index
end

local function anchor(node: GuiObject)
	if messageIndex > 0 then node:SetAttribute(MESSAGE_ATTR, messageIndex) end
end

-- Nearest anchor at or BELOW the index asked for. Below, because a tool_result
-- lives in the user message after the assistant message whose tool-call block is
-- what actually draws it: the result is on screen one message earlier than the
-- message it is stored in.
local function anchorFor(index: number): GuiObject?
	local best: GuiObject? = nil
	local bestAt = 0
	for _, child in ipairs(output:GetChildren()) do
		if child:IsA("GuiObject") then
			local at = child:GetAttribute(MESSAGE_ATTR)
			if type(at) == "number" and at <= index and at > bestAt then
				best = child
				bestAt = at
			end
		end
	end
	return best
end

-- False when that message is not drawn — a replay only renders its tail, and the
-- caller is the one that can do something about it.
function Console.jumpToMessage(index: number): boolean
	local node = anchorFor(index)
	if not node then return false end
	-- Let go of the bottom first, or the Heartbeat pin drags the view straight
	-- back down over the top of the jump.
	stickToBottom = false
	-- Deferred: a jump can follow a redraw, and AbsolutePosition is a frame
	-- behind a layout pass that has not run yet.
	task.defer(function()
		if not node.Parent then return end
		local offset = node.AbsolutePosition.Y - output.AbsolutePosition.Y + output.CanvasPosition.Y
		output.CanvasPosition = Vector2.new(0, math.max(0, offset - 8))
		stickToBottom = false
		-- A flash rather than a permanent highlight: it says which block without
		-- leaving the console marked up afterwards.
		local was = node.BackgroundTransparency
		node.BackgroundColor3 = Theme.ACCENT
		node.BackgroundTransparency = 0.85
		task.delay(FLASH_SECONDS, function()
			if node.Parent then node.BackgroundTransparency = was end
		end)
	end)
	return true
end

-- Peeking at another session mid-turn
-- Moves everything on screen into a holder with no parent and points the sink at
-- it. The blocks stay live Instances, so the running turn goes on writing into
-- the same bubbles and tool-call rows it already holds references to; they are
-- simply not in the DataModel tree, so nothing renders. Reattach puts them back.
--
-- Nil-parented and not just Visible = false, because the console is a
-- ScrollingFrame with AutomaticCanvasSize: an invisible child still costs the
-- layout pass, and a long conversation is thousands of Instances.
--
-- workingRow stays where it is. It is the one thing that SHOULD still be on
-- screen during a peek: it is what says the turn you walked away from is still
-- running.
function Console.detach(): Frame
	local holder = Instance.new("Frame")
	holder.Name = "Detached"
	for _, child in ipairs(output:GetChildren()) do
		if child:IsA("GuiObject") and child ~= workingRow then
			child.Parent = holder
		end
	end
	sink = holder
	return holder
end

function Console.reattach(holder: Frame)
	Console.clear()
	for _, child in ipairs(holder:GetChildren()) do
		child.Parent = output
	end
	holder:Destroy()
	sink = output
	stickToBottom = true
end

-- Draws whatever fn appends into the VISIBLE frame, even while a detached turn
-- owns the sink. Everything the reader asked to see goes through here; the
-- running turn keeps the sink. pcall so a throw cannot leave the sink pointing
-- at the wrong frame for the rest of the session.
-- The peeked-at view is about to be replaced wholesale, so the parked blocks are
-- only going to be destroyed a moment later. Drop them rather than pay to move
-- them back first.
function Console.discard(holder: Frame)
	holder:Destroy()
	sink = output
end

function Console.onScreen(fn: () -> ())
	local previous = sink
	sink = output
	local ok, err = pcall(fn)
	sink = previous
	if not ok then error(err, 0) end
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
	local order = takeOrder()
	local line, setLine = readOnlyBox(
		sink,
		(kind == "user") and Theme.SANS or Theme.MONO,
		Theme.TEXT_SIZE,
		KIND_COLOR[kind or ""] or Theme.TEXT_HI
	)
	line.Name = "Line"
	line.LayoutOrder = order
	anchor(line)

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
		Parent = sink,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		FontFace = Theme.MONO,
		TextSize = Theme.TEXT_SIZE,
		TextColor3 = Theme.ACCENT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		AutoButtonColor = false,
		LayoutOrder = takeOrder(),
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
		Parent = sink,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = takeOrder(),
	})
	anchor(container)
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
	local host = parent or sink
	local container = make("Frame", {
		Name = "ThinkingBlock",
		Parent = host,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder or takeOrder(),
	})
	-- Only reachable when the drawer is a block of its own, which is how a replay
	-- draws it; a live one is nested inside its bubble and the bubble is the
	-- anchor. Either way a thinking hit has somewhere to land.
	anchor(container)
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

	local order = takeOrder()
	local container = make("Frame", {
		Name = "ToolCall",
		Parent = sink,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	})
	anchor(container)
	make("UIListLayout", { Parent = container, SortOrder = Enum.SortOrder.LayoutOrder })

	local header = make("TextButton", {
		Parent = container,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		FontFace = Theme.MONO,
		TextSize = Theme.SMALL_SIZE,
		TextColor3 = isError and Theme.ERR_CLR or Theme.TOOL_CLR,
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

-- Self-test
-- The peek is bookkeeping across two frames and every way it breaks is silent:
-- blocks that never come back, a sink left pointing at a destroyed holder, a
-- LayoutOrder that goes backwards and drops a new block into the middle of an
-- old conversation.
--
-- The checks run inside a pcall with the teardown OUTSIDE it, because the first
-- version of this could fail the console it was testing: it returned early on a
-- failed assertion while the sink was still detached, and every append for the
-- rest of the session went into a frame nobody could see. A self-test that
-- breaks the thing it is checking is worse than no self-test.
function Console.selfTest(): (boolean, string?)
	local holder: Frame? = nil

	local function check(): (boolean, string?)
		Console.clear()
		local first = Console.appendLine("selftest", "info")
		if first.Parent ~= output then return false, "appendLine did not draw into the console" end
		local order = first.LayoutOrder

		holder = Console.detach()
		if first.Parent ~= holder then return false, "detach left a block on screen" end
		if workingRow.Parent ~= output then return false, "detach parked the Working row" end

		-- What the running turn appends while the reader is elsewhere: off screen,
		-- and numbered PAST what is parked rather than into the middle of it. The
		-- holder holds fewer children than the frame it came from, which is exactly
		-- what made counting them wrong.
		local during = Console.appendLine("selftest", "info")
		if during.Parent ~= holder then return false, "a detached turn drew on screen" end
		if during.LayoutOrder <= order then
			return false, "a detached block reused a LayoutOrder already in the conversation"
		end

		-- What the reader opened goes the other way, and the sink goes back after.
		local peeked: TextBox = nil :: any
		Console.onScreen(function() peeked = Console.appendLine("selftest", "info") end)
		if peeked.Parent ~= output then return false, "onScreen drew into the detached holder" end
		if Console.appendLine("selftest", "info").Parent ~= holder then
			return false, "onScreen did not put the sink back"
		end

		Console.reattach(holder :: Frame)
		holder = nil
		if first.Parent ~= output or during.Parent ~= output then
			return false, "reattach did not bring the running turn back"
		end
		if peeked.Parent ~= nil then return false, "reattach kept the peeked session on screen" end
		if Console.appendLine("selftest", "info").Parent ~= output then
			return false, "reattach did not put the sink back"
		end

		-- Anchors. A jump asks for a message index and has to land on the block
		-- that DRAWS it, which for a tool result is one message earlier than the
		-- message the result is stored in — hence at-or-below rather than exact.
		Console.clear()
		Console.setMessage(4)
		local four = Console.appendLine("selftest", "info")
		Console.setMessage(7)
		local seven = Console.appendLine("selftest", "info")
		Console.setMessage(0)
		if Console.appendLine("selftest", "info"):GetAttribute(MESSAGE_ATTR) ~= nil then
			return false, "setMessage(0) anchored a block that belongs to no message"
		end
		if anchorFor(4) ~= four then return false, "anchorFor missed an exact match" end
		if anchorFor(6) ~= four then return false, "anchorFor did not fall back to the message below" end
		if anchorFor(9) ~= seven then return false, "anchorFor did not take the highest below" end
		if anchorFor(3) ~= nil then return false, "anchorFor reached above the index it was asked for" end
		if Console.jumpToMessage(1) then
			return false, "jumpToMessage claimed a message that is not drawn"
		end
		if not Console.jumpToMessage(7) then
			return false, "jumpToMessage could not reach an anchored message"
		end

		-- The live cap. Nothing else bounds how many blocks the console holds, and
		-- an unbounded console makes every layout pass more expensive the longer
		-- the session has run — which is invisible until it is four seconds.
		Console.clear()
		local newest: TextBox = nil :: any
		for index = 1, MAX_BLOCKS + 5 do
			newest = Console.appendLine("selftest " .. index, "info")
		end
		local drawn = 0
		for _, child in ipairs(output:GetChildren()) do
			if child:IsA("GuiObject") and child ~= workingRow then
				drawn += 1
			end
		end
		-- +1: the trim runs before the block it makes room for is created.
		if drawn > MAX_BLOCKS + 1 then
			return false, string.format("the console kept %d blocks, past the cap of %d",
				drawn, MAX_BLOCKS)
		end
		if newest.Parent ~= output then
			return false, "the cap dropped the newest block instead of the oldest"
		end
		if workingRow.Parent ~= output then
			return false, "the cap destroyed the Working row"
		end
		-- A replay draws past the cap on purpose, and trimming underneath it would
		-- destroy the oldest blocks — which are the ones a paging click just
		-- pulled up, and for a Find jump are the message being jumped to.
		local held = drawn
		Console.uncapped(function()
			for index = 1, 5 do
				Console.appendLine("selftest uncapped " .. index, "info")
			end
		end)
		local after = 0
		for _, child in ipairs(output:GetChildren()) do
			if child:IsA("GuiObject") and child ~= workingRow then
				after += 1
			end
		end
		if after ~= held + 5 then
			return false, string.format("uncapped drew %d blocks past a %d cap, not 5",
				after - held, MAX_BLOCKS)
		end
		return true
	end

	local ran, passed, err = pcall(check)
	-- However that went, the console has to be left drawing on screen.
	if holder then (holder :: Frame):Destroy() end
	sink = output
	messageIndex = 0
	stickToBottom = true
	Console.clear()
	if not ran then return false, tostring(passed) end
	return passed, err
end

return Console
