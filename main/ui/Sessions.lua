-- Sessions.luau — saved conversations, and the sidebar that switches between them.
--
-- The conversation IS the session: everything else on screen is derived from it,
-- so persisting `Agent.conversation()` and replaying it through the Console's
-- normal appenders is the whole feature. Nothing new renders here.
--
-- Storage is plugin:SetSetting, same as Settings, so it survives a Studio crash
-- — which is the point. Two kinds of key:
--
--   cc_sessions        the index: id, title, place, updated. Small, rewritten
--                      on every save.
--   cc_session_<id>    one conversation, JSON. Only the ACTIVE session's body is
--                      rewritten, so a save costs one encode rather than all of
--                      them.
--
-- Sessions are tagged with PlaceId and the list is filtered to the current place.
-- Plugin settings are global across places, so without that filter opening the
-- plugin in another game would offer — and auto-restore — a conversation about a
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
-- writing — the same trade Agent makes to keep the context window bounded.
local MAX_BYTES = 400000
local KEEP_RESULTS = 5
local CLEARED = "[old tool result cleared — re-run the command if needed]"

type Entry = { id: string, title: string, place: number, updated: number }

local pluginRef: Plugin = nil :: any
local index: { Entry } = {}
local currentId = ""
local refreshList: (() -> ())? = nil

-- =============================================================================
-- Storage
-- =============================================================================
local function decode(json: any): any?
	if type(json) ~= "string" or json == "" then return nil end
	local ok, value = pcall(function() return HttpService:JSONDecode(json) end)
	return ok and value or nil
end

local function persistIndex()
	pluginRef:SetSetting(KEY_INDEX, HttpService:JSONEncode(index))
end

function Sessions.Initialize(p: Plugin)
	pluginRef = p
	local saved = decode(p:GetSetting(KEY_INDEX))
	if type(saved) == "table" then index = saved end
	currentId = HttpService:GenerateGUID(false)
end

-- First user message, which is what the reader remembers the session by.
local function titleOf(conversation: { any }): string
	for _, message in ipairs(conversation) do
		if message.role == "user" and type(message.content) == "string" then
			local text = (message.content :: string):gsub("%s+", " ")
			if #text > 40 then return text:sub(1, 40) .. "…" end
			if text ~= "" then return text end
		end
	end
	return "Untitled"
end

-- Returns a COPY with all but the last few tool_result contents stubbed. The
-- live conversation is never touched: mutating it here would invalidate the
-- prompt cache from that index onward for a saving the model never asked for.
--
-- Stubbed, not removed — every tool_result pairs with a tool_use that stays, and
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

-- Called on every busy → idle transition, so a crash costs at most the turn that
-- was in flight.
function Sessions.save()
	local conversation = Agent.conversation()
	if #conversation == 0 then return end

	local ok, json = pcall(function() return HttpService:JSONEncode(conversation) end)
	if not ok then
		warn("[Claude Code] session not saved: " .. tostring(json))
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
	entry.title = titleOf(conversation)
	entry.updated = os.time()

	table.sort(index, function(a, b) return a.updated > b.updated end)
	while #index > MAX_SESSIONS do
		local dropped = table.remove(index) :: Entry
		pluginRef:SetSetting(KEY_PREFIX .. dropped.id, nil)
	end
	persistIndex()
	-- No list refresh here: the sidebar redraws every time it opens, and this runs
	-- once per turn whether it is on screen or not.
end

-- =============================================================================
-- Replay
-- =============================================================================
-- Thinking blocks are not in the history (Agent never stores them), so a replay
-- shows prose and tool calls only.
-- ponytail: renders the whole session in one go, so a very long one is a visible
-- hitch on open. Paginate from the tail if that ever bites.
local function replay(conversation: { any })
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

	for _, message in ipairs(conversation) do
		local content = message.content
		if message.role == "user" then
			-- The other shape is a tool_result batch, which is drawn with the call
			-- that produced it rather than as a message of its own.
			if type(content) == "string" then
				Console.appendLine(content, "user")
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
-- as `[]`, and Anthropic rejects `tool_use.input: []` on every later request —
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

-- Switching or clearing mid-turn would leave the running turn appending its
-- results into a conversation nobody is looking at any more.
local function blockedByTurn(): boolean
	if not Agent.isBusy() then return false end
	Console.appendLine("Finish or stop the current turn first.", "error")
	return true
end

function Sessions.load(id: string)
	if blockedByTurn() then return end
	local conversation = decode(pluginRef:GetSetting(KEY_PREFIX .. id))
	if type(conversation) ~= "table" then
		Console.appendLine("That session could not be loaded.", "error")
		return
	end
	repairInputs(conversation)

	currentId = id
	Console.clear()
	Agent.restore(conversation)
	replay(conversation)
	Console.appendLine(string.format("Restored session — %d messages.", #conversation), "system")
end

function Sessions.new()
	if blockedByTurn() then return end
	-- The current session is already on disk: save() runs at the end of every
	-- turn, so there is nothing to flush before letting go of it.
	currentId = HttpService:GenerateGUID(false)
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

-- /clear: the current session is wiped, not archived — its stored copy goes too,
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

-- =============================================================================
-- Sidebar
-- =============================================================================
local function ago(when: number): string
	local seconds = os.time() - when
	if seconds < 60 then return "just now" end
	if seconds < 3600 then return string.format("%dm ago", seconds // 60) end
	if seconds < 86400 then return string.format("%dh ago", seconds // 3600) end
	return string.format("%dd ago", seconds // 86400)
end

-- Same scrim-over-everything shape as the settings panel, so clicking outside
-- closes and no widget below needs to know the sidebar exists.
function Sessions.mountSidebar(parent: Instance): (boolean?) -> ()
	local scrim = make("TextButton", {
		Name = "SessionsScrim",
		Parent = parent,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		ZIndex = 50,
	})

	local panel = make("Frame", {
		Name = "SessionsPanel",
		Parent = scrim,
		BackgroundColor3 = Theme.BG_SURFACE,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 240, 1, 0),
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
		Size = UDim2.new(0, 80, 0, 32),
		Position = UDim2.new(1, -88, 0, 0),
		FontFace = Theme.SANS,
		TextSize = 13,
		TextColor3 = Theme.ACCENT,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "+ New",
		AutoButtonColor = false,
	})

	local list = make("ScrollingFrame", {
		Parent = panel,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -1, 1, -36),
		Position = UDim2.new(0, 0, 0, 36),
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
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
			if entry.place == game.PlaceId then
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
					FontFace = Theme.SANS,
					TextSize = 14,
					TextColor3 = Theme.TEXT_LO,
					Text = "✕",
					AutoButtonColor = false,
				})

				local id = entry.id
				row.MouseButton1Click:Connect(function()
					if id ~= currentId then Sessions.load(id) end
					scrim.Visible = false
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
				Text = "No saved sessions yet.",
			})
		end
	end
	refreshList = draw

	newButton.MouseButton1Click:Connect(function()
		Sessions.new()
		scrim.Visible = false
	end)
	-- Clicks on the panel never reach the scrim, so this only fires outside it.
	scrim.MouseButton1Click:Connect(function() scrim.Visible = false end)

	return function(visible: boolean?)
		local show = if visible == nil then not scrim.Visible else visible
		if show then draw() end
		scrim.Visible = show
	end
end

-- =============================================================================
-- Self-test
-- =============================================================================
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

	return true
end

return Sessions
