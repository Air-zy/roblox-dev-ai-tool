-- Sessions.luau: saved conversations, and the sidebar that switches between them.
--
-- The conversation IS the session: everything else on screen is derived from it,
-- so persisting `Agent.conversation()` and replaying it through the Console's
-- normal appenders is the whole feature. Nothing new renders here.
--
-- Storage is plugin:SetSetting, same as Settings, so it survives a Studio crash
--, which is the point. Two kinds of key:
--
--   cc_sessions        the index: id, title, place, updated. Small, rewritten
--                      on every save.
--   cc_session_<id>    one conversation, JSON. Only the ACTIVE session's body is
--                      rewritten, so a save costs one encode rather than all of
--                      them.
--
-- Sessions are tagged with PlaceId and the list is filtered to the current place.
-- Plugin settings are global across places, so without that filter opening the
-- plugin in another game would offer, and auto-restore, a conversation about a
-- different DataModel entirely.

local HttpService = game:GetService("HttpService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local Console = require(script.Parent:WaitForChild("Console"))
local Agent = require(script.Parent.Parent:WaitForChild("agent"):WaitForChild("Agent"))

local make = Theme.make

local Sessions = {}

local KEY_INDEX = "cc_sessions"
local KEY_PREFIX = "cc_session_"

local MAX_SESSIONS = 20
-- SetSetting writes to a local JSON file with no documented ceiling, but a
-- session carrying a few `cat`s of large ModuleScripts is megabytes, and that
-- cost is paid on every turn. Past this the old tool results are stubbed before
-- writing: the same trade Agent makes to keep the context window bounded.
local MAX_BYTES = 400000
local KEEP_RESULTS = 5
local CLEARED = "[old tool result cleared — re-run the command if needed]"

type Entry = { id: string, title: string, place: number, updated: number }

local pluginRef: Plugin = nil :: any
local index: { Entry } = {}
local currentId = ""
local refreshList: (() -> ())? = nil

-- Storage
local function decode(json: any): any?
	if type(json) ~= "string" or json == "" then return nil end
	local ok, value = pcall(function() return HttpService:JSONDecode(json) end)
	return ok and value or nil
end

local function persistIndex()
	pluginRef:SetSetting(KEY_INDEX, HttpService:JSONEncode(index))
end

-- The active row is drawn differently, so every change of session has to redraw
-- the list or the highlight stays on the one you just left. Going through a
-- setter is what keeps that true for all three ways currentId moves, switch,
-- new, delete, rather than only the one that remembered to refresh. Defined up
-- here because Initialize is the first caller and a `local function` is not in
-- scope above its own definition.
local function setCurrent(id: string)
	currentId = id
	if refreshList then refreshList() end
end

function Sessions.Initialize(p: Plugin)
	pluginRef = p
	local saved = decode(p:GetSetting(KEY_INDEX))
	if type(saved) == "table" then index = saved end
	setCurrent(HttpService:GenerateGUID(false))
end

-- What the reader typed, whichever shape it is stored in. A user message is
-- normally a plain string, but sessions saved before Claude.withMessageCache
-- stopped writing into the live conversation have theirs as a one-element text
-- block array, those still have to restore and still have to be titled.
-- Returns nil for the other block shape, a tool_result batch, which is drawn
-- with the call that produced it rather than as a message of its own.
local function userText(message: any): string?
	local content = message.content
	if type(content) == "string" then
		return content ~= "" and content or nil
	end
	if type(content) ~= "table" then return nil end
	local parts: { string } = {}
	for _, block in ipairs(content) do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
			table.insert(parts, block.text)
		end
	end
	return #parts > 0 and table.concat(parts, "\n") or nil
end

-- First user message, which is what the reader remembers the session by.
-- Returns nil when there isn't one, a session resumed from a stop or an error
-- can begin with a tool_result batch and nothing else, and "Untitled" tells you
-- less than the clock does.
local function titleOf(conversation: { any }): string?
	for _, message in ipairs(conversation) do
		if message.role == "user" then
			local raw = userText(message)
			if raw then
				local text = raw:gsub("%s+", " ")
				if #text > 40 then return text:sub(1, 40) .. "…" end
				if text ~= "" then return text end
			end
		end
	end
	return nil
end

-- Returns a COPY with all but the last few tool_result contents stubbed. The
-- live conversation is never touched: mutating it here would invalidate the
-- prompt cache from that index onward for a saving the model never asked for.
--
-- Stubbed, not removed, every tool_result pairs with a tool_use that stays, and
-- a restored session with a broken pairing is rejected on its next request.
local function stubOldResults(conversation: { any }): { any }
	local total = 0
	for _, message in ipairs(conversation) do
		if type(message.content) == "table" then
			for _, block in ipairs(message.content) do
				if block.type == "tool_result" then total += 1 end
			end
		end
	end
	local cutoff = total - KEEP_RESULTS
	if cutoff <= 0 then return conversation end

	local seen = 0
	local out = table.clone(conversation)
	for i, message in ipairs(out) do
		if type(message.content) == "table" then
			local content = table.clone(message.content)
			local changed = false
			for j, block in ipairs(content) do
				if block.type == "tool_result" then
					seen += 1
					if seen <= cutoff and type(block.content) == "string" and #block.content > #CLEARED then
						local stub = table.clone(block)
						stub.content = CLEARED
						content[j] = stub
						changed = true
					end
				end
			end
			if changed then
				local copy = table.clone(message)
				copy.content = content
				out[i] = copy
			end
		end
	end
	return out
end

local function entryFor(id: string): Entry?
	for _, entry in ipairs(index) do
		if entry.id == id then return entry end
	end
	return nil
end

-- Called on every busy -> idle transition, so a crash costs at most the turn that
-- was in flight.
function Sessions.save()
	local conversation = Agent.conversation()
	if #conversation == 0 then return end

	local ok, json = pcall(function() return HttpService:JSONEncode(conversation) end)
	if not ok then
		warn("[agent] session not saved: " .. tostring(json))
		return
	end
	if #json > MAX_BYTES then
		json = HttpService:JSONEncode(stubOldResults(conversation))
	end
	pluginRef:SetSetting(KEY_PREFIX .. currentId, json)

	local entry = entryFor(currentId)
	if not entry then
		entry = { id = currentId, title = "", place = game.PlaceId, updated = 0 }
		table.insert(index, entry :: Entry)
	end
	-- Retitled every save rather than once at creation: /clear empties the
	-- conversation without changing session, so the title has to follow whatever
	-- the first message is NOW.
	entry.title = titleOf(conversation) or (os.date("%b %d, %H:%M") :: string)
	entry.updated = os.time()

	table.sort(index, function(a, b) return a.updated > b.updated end)
	while #index > MAX_SESSIONS do
		local dropped = table.remove(index) :: Entry
		pluginRef:SetSetting(KEY_PREFIX .. dropped.id, nil)
	end
	persistIndex()
	-- The drawer stays open while you work, so the row for the session you are
	-- IN has to pick up its new title and time as they change.
	if refreshList then refreshList() end
end

-- Replay
-- Thinking blocks ARE in the history now, the tool-use protocol requires them
-- but nothing here matches their type, so a replay still shows prose and tool
-- calls only. Rendering a restored session's reasoning would mean a drawer per
-- block; the live view is where reasoning is worth reading.
-- Only the tail is drawn. Every message is a handful of Instances and a Markdown
-- parse, so rendering a long session in full froze Studio for about a second on
-- every switch. The conversation Agent restored is still the WHOLE thing, this
-- caps what is on screen, not what Claude can see.
--
-- The rest is a page away, not gone: the top line is a button that widens the
-- window and redraws. `shown` is reset by load(), so every session opens at one
-- page again.
--
-- ponytail: paging redraws the whole window rather than prepending to it, so
-- clicking back through a very long session pays the freeze it was avoiding
-- but only on a click the reader asked for. Prepending needs LayoutOrder below
-- what is already on screen, which every appender computes for itself; do that
-- if the redraw ever gets annoying.
local REPLAY_MESSAGES = 25
local shown = REPLAY_MESSAGES

-- Switching, clearing or paging mid-turn would leave the running turn appending
-- its results into a view nobody is looking at any more.
local function blockedByTurn(): boolean
	if not Agent.isBusy() then return false end
	Console.appendLine("Finish or stop the current turn first.", "error")
	return true
end

local function replay(conversation: { any })
	-- Built from the FULL conversation: a tool_use in the tail can be paired with
	-- a tool_result whose message was cut, and a call that renders without its
	-- result is a call that looks like it never finished.
	local results: { [string]: string } = {}
	for _, message in ipairs(conversation) do
		if type(message.content) == "table" then
			for _, block in ipairs(message.content) do
				if block.type == "tool_result" and block.tool_use_id then
					results[block.tool_use_id] = tostring(block.content)
				end
			end
		end
	end

	local first = math.max(1, #conversation - shown + 1)
	if first > 1 then
		Console.appendLink(
			string.format("↑ Load %d earlier messages (%d older)",
				math.min(REPLAY_MESSAGES, first - 1), first - 1),
			function()
				-- Same guard as switching sessions: redrawing would destroy the
				-- bubble a running turn is streaming into.
				if blockedByTurn() then return end
				shown += REPLAY_MESSAGES
				Console.clear()
				replay(conversation)
				-- The reader clicked the thing at the top, so leave them at the top
				-- looking at the messages they just pulled up, not back at the newest.
				Console.scrollToTop()
			end)
	end

	for index = first, #conversation do
		local message = conversation[index]
		local content = message.content
		if message.role == "user" then
			local typed = userText(message)
			if typed then
				Console.appendLine(typed, "user")
			end
		elseif type(content) == "string" then
			Console.createBubble().setText(content)
		elseif type(content) == "table" then
			local text: { string } = {}
			for _, block in ipairs(content) do
				if block.type == "text" and block.text then
					table.insert(text, block.text)
				end
			end
			if #text > 0 then
				Console.createBubble().setText(table.concat(text, "\n"))
			end
			for _, block in ipairs(content) do
				if block.type == "tool_use" or block.type == "server_tool_use" then
					-- A result is always passed: appendToolCall spins forever without
					-- one. Server tool results live in their own replayed block, not
					-- in `results`, so those show the placeholder.
					Console.appendToolCall(
						tostring(block.name),
						type(block.input) == "table" and block.input or {},
						results[block.id] or "(result not stored)")
				end
			end
		end
	end
end

-- JSON has no empty-object form that survives the round trip: an argument-less
-- tool_use saved as `{}` comes back as an empty Lua table, which Roblox re-encodes
-- as `[]`, and Anthropic rejects `tool_use.input: []` on every later request
-- the same failure Agent.toolInput guards at stream time. Refill it here.
local function repairInputs(conversation: { any })
	for _, message in ipairs(conversation) do
		if type(message.content) == "table" then
			for _, block in ipairs(message.content) do
				if (block.type == "tool_use" or block.type == "server_tool_use")
					and type(block.input) == "table" and next(block.input) == nil then
					block.input = { _restored = "input not stored" }
				end
			end
		end
	end
end

function Sessions.load(id: string)
	if blockedByTurn() then return end
	local conversation = decode(pluginRef:GetSetting(KEY_PREFIX .. id))
	if type(conversation) ~= "table" then
		Console.appendLine("That session could not be loaded.", "error")
		return
	end
	repairInputs(conversation)

	setCurrent(id)
	Console.clear()
	Agent.restore(conversation)
	shown = REPLAY_MESSAGES
	replay(conversation)
	Console.appendLine(string.format("Restored session — %d messages.", #conversation), "system")
end

function Sessions.new()
	if blockedByTurn() then return end
	-- The current session is already on disk: save() runs at the end of every
	-- turn, so there is nothing to flush before letting go of it.
	setCurrent(HttpService:GenerateGUID(false))
	Console.clear()
	Agent.reset()
end

function Sessions.delete(id: string)
	if id == currentId and blockedByTurn() then return end
	pluginRef:SetSetting(KEY_PREFIX .. id, nil)
	for i, entry in ipairs(index) do
		if entry.id == id then
			table.remove(index, i)
			break
		end
	end
	persistIndex()
	-- Deleting the session you are IN leaves you on a blank one rather than
	-- looking at a conversation that no longer exists anywhere.
	if id == currentId then
		Sessions.new()
	end
	if refreshList then refreshList() end
end

-- /clear: the current session is wiped, not archived, its stored copy goes too,
-- or the next open would restore the thing that was just cleared.
function Sessions.clear()
	Sessions.delete(currentId)
end

-- Most recent session for THIS place, restored on open so a crash costs no
-- clicks. Silent when there is nothing to restore.
function Sessions.restoreLast()
	for _, entry in ipairs(index) do
		if entry.place == game.PlaceId then
			Sessions.load(entry.id)
			return
		end
	end
end

-- Sidebar
local function ago(when: number): string
	local seconds = os.time() - when
	if seconds < 60 then return "just now" end
	if seconds < 3600 then return string.format("%dm ago", seconds // 60) end
	if seconds < 86400 then return string.format("%dh ago", seconds // 3600) end
	return string.format("%dd ago", seconds // 86400)
end

-- Deliberately NOT a scrim-and-card like the settings popup. This one is a
-- drawer: it stays until it is closed from the same button that opened it, and
-- the caller shifts the console over by WIDTH rather than having it covered, so
-- you can read a session and keep working. Nothing here is modal, which is why
-- there is no full-bleed catcher to swallow clicks meant for the console.
--
-- Returns a toggle that reports the state it settled on, since the shift lives
-- with the caller.
Sessions.WIDTH = 240

function Sessions.mountSidebar(parent: Instance, openSettings: () -> ()): (boolean?) -> boolean
	local panel = make("Frame", {
		Name = "SessionsPanel",
		Parent = parent,
		BackgroundColor3 = Theme.BG_SURFACE,
		BorderSizePixel = 0,
		Size = UDim2.new(0, Sessions.WIDTH, 1, 0),
		Visible = false,
	})
	make("Frame", {
		Parent = panel,
		BackgroundColor3 = Theme.BORDER,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 1, 1, 0),
		Position = UDim2.new(1, -1, 0, 0),
	})

	make("TextLabel", {
		Parent = panel,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -100, 0, 32),
		Position = UDim2.new(0, 12, 0, 0),
		FontFace = Theme.SANS_BOLD,
		TextSize = 13,
		TextColor3 = Theme.TEXT_MED,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Sessions",
	})
	local newButton = make("TextButton", {
		Parent = panel,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 32, 0, 32),
		Position = UDim2.new(1, -36, 0, 0),
		FontFace = Theme.ICON,
		TextSize = 16,
		TextColor3 = Theme.ACCENT,
		Text = "plus-large",
		AutoButtonColor = false,
	})

	-- Pinned to the bottom, out of the header: the gear is a once-a-session
	-- control and the header row it used to sit in is now two clicks of nothing.
	-- 32px, the same as the header bar and the input row, so the drawer's top and
	-- bottom edges line up with the console's.
	local settingsRow = make("TextButton", {
		Parent = panel,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -1, 0, 32),
		Position = UDim2.new(0, 0, 1, -32),
		Text = "",
		AutoButtonColor = false,
	})
	make("Frame", {
		Parent = settingsRow,
		BackgroundColor3 = Theme.BORDER,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	})
	make("TextLabel", {
		Parent = settingsRow,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 20, 1, 0),
		Position = UDim2.new(0, 10, 0, 0),
		FontFace = Theme.ICON,
		TextSize = 16,
		TextColor3 = Theme.TEXT_MED,
		Text = "gear",
	})
	make("TextLabel", {
		Parent = settingsRow,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -44, 1, 0),
		Position = UDim2.new(0, 36, 0, 0),
		FontFace = Theme.SANS,
		TextSize = 13,
		TextColor3 = Theme.TEXT_MED,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Settings",
	})
	settingsRow.MouseButton1Click:Connect(openSettings)

	-- Filters on TITLE only, which is the first 40 characters of the first message
	-- you sent. That is what you remember a session by, and it costs one string
	-- find per row, so the list narrows on the keystroke. Searching the bodies
	-- would mean reading and decoding twenty stored conversations, up to 400 KB
	-- each, on a keystroke; Ctrl+F searches a conversation once it is open.
	local query = ""
	local searchRow = make("Frame", {
		Parent = panel,
		BackgroundColor3 = Theme.BG_INPUT,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -17, 0, 24),
		Position = UDim2.new(0, 8, 0, 34),
	})
	make("UICorner", { Parent = searchRow, CornerRadius = UDim.new(0, 4) })
	make("TextLabel", {
		Parent = searchRow,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 14, 1, 0),
		Position = UDim2.new(0, 6, 0, 0),
		FontFace = Theme.ICON,
		TextSize = 12,
		TextColor3 = Theme.TEXT_LO,
		Text = "magnifying-glass",
	})
	local searchBox = make("TextBox", {
		Parent = searchRow,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -32, 1, 0),
		Position = UDim2.new(0, 26, 0, 0),
		FontFace = Theme.SANS,
		TextSize = 12,
		TextColor3 = Theme.TEXT_HI,
		ClearTextOnFocus = false,
		MultiLine = false,
		Text = "",
		PlaceholderText = "Search sessions…",
		PlaceholderColor3 = Theme.TEXT_LO,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local list = make("ScrollingFrame", {
		Parent = panel,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- 32 of header plus the 26 the search row occupies above, 32 of settings
		-- row below; the header and the settings row are the same height as the
		-- console's header and input row.
		Size = UDim2.new(1, -1, 1, -94),
		Position = UDim2.new(0, 0, 0, 62),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.TEXT_LO,
	})
	make("UIListLayout", { Parent = list, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder })
	make("UIPadding", { Parent = list, PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) })

	local function draw()
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		local order = 0
		for _, entry in ipairs(index) do
			if entry.place == game.PlaceId
				and (query == "" or entry.title:lower():find(query, 1, true) ~= nil) then
				order += 1
				local active = entry.id == currentId
				local row = make("TextButton", {
					Parent = list,
					BackgroundColor3 = Theme.BG_INPUT,
					BackgroundTransparency = active and 0 or 1,
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, 40),
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = order,
				})
				make("UICorner", { Parent = row, CornerRadius = UDim.new(0, 4) })
				make("TextLabel", {
					Parent = row,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, -40, 0, 20),
					Position = UDim2.new(0, 8, 0, 3),
					FontFace = Theme.SANS,
					TextSize = 13,
					TextColor3 = active and Theme.ACCENT or Theme.TEXT_HI,
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = entry.title,
				})
				make("TextLabel", {
					Parent = row,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, -40, 0, 14),
					Position = UDim2.new(0, 8, 0, 22),
					FontFace = Theme.SANS,
					TextSize = 11,
					TextColor3 = Theme.TEXT_LO,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = ago(entry.updated),
				})
				local remove = make("TextButton", {
					Parent = row,
					BackgroundTransparency = 1,
					Size = UDim2.new(0, 28, 1, 0),
					Position = UDim2.new(1, -28, 0, 0),
					FontFace = Theme.ICON,
					TextSize = 14,
					TextColor3 = Theme.TEXT_LO,
					Text = "trash-can",
					-- Hidden by transparency, not Visible: an invisible button stops
					-- receiving MouseEnter, and the row fires MouseLeave the moment the
					-- cursor crosses onto a child, so Visible = false would make the icon
					-- flicker itself out from under the mouse.
					TextTransparency = 1,
					AutoButtonColor = false,
				})

				row.MouseEnter:Connect(function()
					remove.TextTransparency = 0
					remove.TextColor3 = Theme.TEXT_LO
				end)
				row.MouseLeave:Connect(function() remove.TextTransparency = 1 end)
				remove.MouseEnter:Connect(function()
					remove.TextTransparency = 0
					remove.TextColor3 = Theme.TEXT_HI
				end)
				remove.MouseLeave:Connect(function()
					remove.TextTransparency = 1
					remove.TextColor3 = Theme.TEXT_LO
				end)

				local id = entry.id
				-- The drawer stays open on a switch: picking the wrong session and
				-- picking the next one should not cost two more clicks.
				row.MouseButton1Click:Connect(function()
					if id ~= currentId then Sessions.load(id) end
				end)
				remove.MouseButton1Click:Connect(function()
					Sessions.delete(id)
				end)
			end
		end
		if order == 0 then
			make("TextLabel", {
				Parent = list,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 40),
				FontFace = Theme.SANS,
				TextSize = 12,
				TextColor3 = Theme.TEXT_LO,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = if query == "" then "No saved sessions yet." else "Nothing matches that.",
			})
		end
	end
	-- Only worth drawing while it is on screen, it stays open now, so save() can
	-- call this on every turn without rebuilding rows nobody is looking at.
	refreshList = function()
		if panel.Visible then draw() end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		query = searchBox.Text:lower()
		draw()
	end)

	newButton.MouseButton1Click:Connect(Sessions.new)

	return function(visible: boolean?): boolean
		panel.Visible = if visible == nil then not panel.Visible else visible
		if panel.Visible then draw() end
		return panel.Visible
	end
end

-- Self-test
-- Both halves fail as a session that loads and then dies on its next request:
-- a stub that drops a tool_result breaks the tool_use pairing, and an empty
-- tool_use input re-encodes as `[]` and is rejected outright.
function Sessions.selfTest(): (boolean, string?)
	local big = string.rep("x", 5000)
	local conversation: { any } = {}
	for i = 1, 8 do
		table.insert(conversation, { role = "assistant", content = {
			{ type = "tool_use", id = "t" .. i, name = "bash", input = { command = "ls" } },
		} })
		table.insert(conversation, { role = "user", content = {
			{ type = "tool_result", tool_use_id = "t" .. i, content = big },
		} })
	end

	local stubbed = stubOldResults(conversation)
	local kept, cleared = 0, 0
	for _, message in ipairs(stubbed) do
		if type(message.content) == "table" then
			for _, block in ipairs(message.content) do
				if block.type == "tool_result" then
					if block.content == CLEARED then cleared += 1 else kept += 1 end
					if block.content == "" then return false, "stubOldResults emptied a tool_result" end
				end
			end
		end
	end
	if kept + cleared ~= 8 then
		return false, "stubOldResults changed the number of tool_result blocks"
	end
	if cleared ~= 8 - KEEP_RESULTS then
		return false, string.format("stubOldResults cleared %d results, expected %d", cleared, 8 - KEEP_RESULTS)
	end
	-- The live conversation must be untouched, or saving would invalidate the
	-- prompt cache mid-session.
	for _, message in ipairs(conversation) do
		if type(message.content) == "table" and message.content[1].type == "tool_result"
			and message.content[1].content ~= big then
			return false, "stubOldResults mutated the live conversation"
		end
	end

	local roundTripped = decode(HttpService:JSONEncode({
		{ role = "assistant", content = { { type = "tool_use", id = "a", name = "catalog", input = {} } } },
	}))
	repairInputs(roundTripped :: any)
	if next((roundTripped :: any)[1].content[1].input) == nil then
		return false, "repairInputs left an empty tool_use input, which the API rejects"
	end

	if titleOf({ { role = "user", content = "hello  world" } }) ~= "hello world" then
		return false, "titleOf did not normalise whitespace"
	end

	-- The older on-disk shape, where the cache breakpoint had rewritten the user
	-- message into blocks. Both the title and the replayed line come from
	-- userText, so this one assertion covers a session that restores with the
	-- reader's own messages missing.
	local blockShaped = { role = "user", content = { { type = "text", text = "old  shape" } } }
	if titleOf({ blockShaped }) ~= "old shape" then
		return false, "userText did not read a block-shaped user message from an older session"
	end
	if userText({ role = "user", content = {
		{ type = "tool_result", tool_use_id = "t1", content = "ls" },
	} }) ~= nil then
		return false, "userText mistook a tool_result batch for something the reader typed"
	end

	return true
end

return Sessions
