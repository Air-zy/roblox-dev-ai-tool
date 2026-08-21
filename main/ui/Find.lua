--!strict
-- Find.luau: search the conversation you are in.
--
-- Searches the CONVERSATION, not the console. What is on screen is only the last
-- 25 messages of a restored session, and Sessions.replay deliberately never
-- redraws thinking blocks, so a find over the rendered labels would quietly miss
-- most of what it was asked for. The conversation holds every message, every
-- thinking block and every tool result, which is why a hit comes back as a
-- snippet in this panel rather than as a scroll position in the output frame.

local Theme = require(script.Parent:WaitForChild("Theme"))

local make = Theme.make

local Find = {}

-- One hit per matching BLOCK, not per occurrence: a grep result carrying forty
-- copies of the word would otherwise be forty rows and a count nobody can act
-- on. The snippet is cut at the first occurrence in that block.
--
-- `at` is the message the block belongs to. It is the whole point of the row:
-- clicking one scrolls the console to that message, and the snippet is only
-- there so you can tell the hits apart before you go.
export type Hit = { kind: string, snippet: string, at: number }

local CONTEXT = 70
local MIN_QUERY = 2
local ROW_ESTIMATE = 46
local LIST_HEIGHT = 220

local function snippetAt(text: string, at: number, len: number): string
	local from = math.max(1, at - CONTEXT)
	local to = math.min(#text, at + len - 1 + CONTEXT)
	local cut = (text:sub(from, to):gsub("%s+", " "))
	return (if from > 1 then "…" else "") .. cut .. (if to < #text then "…" else "")
end

-- A tool call's arguments are a table; flattened to one line so the command, the
-- path or the pattern is searchable the same way prose is. Sorted, so the same
-- call always reads the same way.
local function argText(input: any): string
	if type(input) ~= "table" then return tostring(input) end
	local parts: { string } = {}
	for key, value in pairs(input) do
		parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
	end
	table.sort(parts)
	return table.concat(parts, "  ")
end

-- A tool result's content is a string as Agent writes it, but a server tool's
-- comes back as the block-array form.
local function resultText(content: any): string
	if type(content) == "string" then return content end
	if type(content) ~= "table" then return tostring(content) end
	local parts: { string } = {}
	for _, block in ipairs(content) do
		if type(block) == "table" and type(block.text) == "string" then
			parts[#parts + 1] = block.text
		end
	end
	return table.concat(parts, "\n")
end

-- Plain substring, case-insensitive. Not a pattern: the reader is looking for a
-- variable name or a path, and `Workspace.Part` read as a Lua pattern matches
-- things that are not it.
function Find.scan(conversation: { any }, query: string): { Hit }
	local needle = query:lower()
	local hits: { Hit } = {}

	local function try(kind: string, value: any, at: number)
		if type(value) ~= "string" or value == "" then return end
		local found = value:lower():find(needle, 1, true)
		if not found then return end
		hits[#hits + 1] = {
			kind = kind,
			snippet = snippetAt(value, found, #needle),
			at = at,
		}
	end

	for at, message in ipairs(conversation) do
		local who = if message.role == "user" then "you" else "claude"
		local content = message.content
		if type(content) == "string" then
			try(who, content, at)
		elseif type(content) == "table" then
			for _, block in ipairs(content) do
				if type(block) ~= "table" then continue end
				if block.type == "text" then
					try(who, block.text, at)
				elseif block.type == "thinking" then
					try("thinking", block.thinking, at)
				elseif block.type == "tool_use" or block.type == "server_tool_use" then
					try(tostring(block.name), argText(block.input), at)
				elseif block.type == "tool_result" then
					try("result", resultText(block.content), at)
				end
			end
		end
	end
	return hits
end

local function kindColor(kind: string): Color3
	if kind == "you" then return Theme.ACCENT end
	if kind == "claude" then return Theme.TEXT_HI end
	if kind == "thinking" then return Theme.THINK_CLR end
	return Theme.TOOL_CLR
end

-- Panel
-- Over the console rather than in the layout: opening a find bar should not
-- reflow the conversation you are reading. The sessions drawer is on the left
-- and shifts `root` rather than the widget, so this never has to know about it.
--
-- Bottom right, above the input row, the same corner the model picker uses. Not
-- the top, which is where clicking a result scrolls the message TO: a panel
-- there sits on top of the thing it just took you to. `liftBy` is how far up,
-- since the input row grows with the draft in it and only the caller knows how
-- tall it is right now.
Find.WIDTH = 360

function Find.mount(
	parent: Instance,
	getConversation: () -> { any },
	jumpTo: (index: number) -> (),
	liftBy: () -> number
): (boolean?, string?) -> boolean
	local panel = make("Frame", {
		Name = "FindPanel",
		Parent = parent,
		BackgroundColor3 = Theme.BG_SURFACE,
		BorderColor3 = Theme.BORDER,
		BorderSizePixel = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -8, 1, -40),
		Size = UDim2.new(0, Find.WIDTH, 0, 32),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		ZIndex = 50,
	})
	make("UIListLayout", { Parent = panel, SortOrder = Enum.SortOrder.LayoutOrder })

	local queryRow = make("Frame", {
		Parent = panel,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = 1,
		ZIndex = 51,
	})
	make("TextLabel", {
		Parent = queryRow,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 16, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		FontFace = Theme.ICON,
		TextSize = 14,
		TextColor3 = Theme.TEXT_LO,
		Text = "magnifying-glass",
		ZIndex = 51,
	})
	local queryBox = make("TextBox", {
		Parent = queryRow,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -136, 1, 0),
		Position = UDim2.new(0, 30, 0, 0),
		FontFace = Theme.SANS,
		TextSize = Theme.SMALL_SIZE,
		TextColor3 = Theme.TEXT_HI,
		ClearTextOnFocus = false,
		MultiLine = false,
		Text = "",
		PlaceholderText = "Find in this chat…",
		PlaceholderColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 51,
	})
	local count = make("TextLabel", {
		Parent = queryRow,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -30, 0, 0),
		Size = UDim2.new(0, 96, 1, 0),
		FontFace = Theme.SANS,
		TextSize = Theme.SMALL_SIZE,
		TextColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		ZIndex = 51,
	})
	local close = make("TextButton", {
		Parent = queryRow,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 0),
		Size = UDim2.new(0, 22, 1, 0),
		FontFace = Theme.ICON,
		TextSize = 14,
		TextColor3 = Theme.TEXT_LO,
		Text = "x",
		AutoButtonColor = false,
		ZIndex = 51,
	})

	local results = make("ScrollingFrame", {
		Parent = panel,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.TEXT_LO,
		LayoutOrder = 2,
		ZIndex = 51,
	})
	make("UIListLayout", { Parent = results, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder })
	make("UIPadding", { Parent = results, PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) })

	local hits: { Hit } = {}

	local function draw()
		for _, child in ipairs(results:GetChildren()) do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		for i, hit in ipairs(hits) do
			local row = make("TextButton", {
				Parent = results,
				BackgroundColor3 = Theme.BG_INPUT,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = i,
				ZIndex = 52,
			})
			make("UIPadding", {
				Parent = row,
				PaddingTop = UDim.new(0, 4),
				PaddingBottom = UDim.new(0, 4),
			})
			make("TextLabel", {
				Parent = row,
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 56, 0, 16),
				FontFace = Theme.MONO,
				TextSize = Theme.SMALL_SIZE,
				TextColor3 = kindColor(hit.kind),
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = hit.kind,
				ZIndex = 52,
			})
			-- RichText stays off: a snippet is arbitrary text out of the
			-- conversation, and half of what is in there has angle brackets in it.
			make("TextLabel", {
				Parent = row,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -62, 0, 0),
				Position = UDim2.new(0, 62, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				FontFace = Theme.SANS,
				TextSize = Theme.SMALL_SIZE,
				TextColor3 = Theme.TEXT_MED,
				TextWrapped = true,
				RichText = false,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Text = hit.snippet,
				ZIndex = 52,
			})

			row.MouseEnter:Connect(function() row.BackgroundTransparency = 0 end)
			row.MouseLeave:Connect(function() row.BackgroundTransparency = 1 end)
			-- The panel is a way to the message, not a place to read it. The panel
			-- stays open so the next result is one more click.
			row.MouseButton1Click:Connect(function() jumpTo(hit.at) end)
		end
		-- An estimate, and it is allowed to be wrong: the list scrolls, so a row
		-- that wraps to three lines costs a scroll rather than being unreachable.
		results.Size = UDim2.new(1, 0, 0, math.min(LIST_HEIGHT, #hits * ROW_ESTIMATE))
	end

	local function search()
		local query = queryBox.Text
		if #query < MIN_QUERY then
			hits = {}
			count.Text = ""
		else
			hits = Find.scan(getConversation(), query)
			count.Text = if #hits == 0 then "no matches" else string.format("%d found", #hits)
		end
		draw()
	end
	queryBox:GetPropertyChangedSignal("Text"):Connect(search)

	local function setVisible(visible: boolean): boolean
		panel.Visible = visible
		if visible then
			panel.Position = UDim2.new(1, -8, 1, -liftBy())
			-- Re-run rather than trust what is on screen: turns have landed since
			-- this was last open.
			search()
			queryBox:CaptureFocus()
			-- Reopening with the last query still in the box, selected, so typing
			-- replaces it and Enter-less repeat searching costs nothing.
			queryBox.CursorPosition = #queryBox.Text + 1
			queryBox.SelectionStart = 1
		end
		return visible
	end

	close.MouseButton1Click:Connect(function() setVisible(false) end)
	-- Esc hands back the key that dropped focus, which is the only way a cancel
	-- from the keyboard reaches a plugin widget while a box holds it. Enter has
	-- nothing to do here, results are live as you type, so it just keeps focus.
	queryBox.FocusLost:Connect(function(enterPressed: boolean, cause: InputObject?)
		if cause and cause.KeyCode == Enum.KeyCode.Escape then
			setVisible(false)
		elseif enterPressed then
			queryBox:CaptureFocus()
		end
	end)

	-- `query` prefills the box, which is what /find passes: the one trigger that
	-- works while you are typing, since that is exactly when no key event reaches
	-- the widget at all.
	return function(visible: boolean?, query: string?): boolean
		local show = if visible == nil then not panel.Visible else visible
		if show and query and query ~= "" then queryBox.Text = query end
		return setVisible(show)
	end
end

-- Self-test
-- The failure this exists for is silent: a scan that reads prose but skips
-- reasoning or tool output still returns hits, so it looks like it worked.
function Find.selfTest(): (boolean, string?)
	local conversation: { any } = {
		{ role = "user", content = "make the Baseplate red" },
		{ role = "assistant", content = {
			{ type = "thinking", thinking = "it is called Baseplate, so recolour that one" },
			{ type = "text", text = "Done." },
			{ type = "tool_use", id = "t1", name = "bash", input = { command = "ls /Workspace/Baseplate" } },
		} },
		{ role = "user", content = {
			{ type = "tool_result", tool_use_id = "t1", content = "Baseplate\nSpawnLocation" },
		} },
	}

	-- Reasoning is the only block carrying this word, and the match is
	-- case-insensitive in both directions.
	local think = Find.scan(conversation, "RECOLOUR")
	if #think ~= 1 or think[1].kind ~= "thinking" then
		return false, "scan missed a thinking block, or mislabelled it"
	end
	-- The index is what a click navigates by; a hit that reports the wrong one
	-- scrolls to the wrong place, which looks like the search being wrong.
	if think[1].at ~= 2 then
		return false, "scan reported the wrong message index for a thinking block"
	end

	local kinds: { [string]: number } = {}
	for _, hit in ipairs(Find.scan(conversation, "baseplate")) do
		kinds[hit.kind] = hit.at
	end
	for kind, at in pairs({ you = 1, thinking = 2, bash = 2, result = 3 }) do
		if kinds[kind] ~= at then
			return false, string.format("scan put %s at message %s, expected %d",
				kind, tostring(kinds[kind]), at)
		end
	end

	if #Find.scan(conversation, "not in here anywhere") ~= 0 then
		return false, "scan matched a query the conversation does not contain"
	end
	return true
end

return Find
