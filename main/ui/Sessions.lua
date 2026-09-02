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
--   cc_session_<slot>  one conversation, JSON. Only the ACTIVE session's body is
--                      rewritten, so a save costs one encode rather than all of
--                      them.
--
-- <slot> is a number, 1..MAX_SESSIONS, and that is load-bearing rather than
-- tidy: Roblox has no way to LIST a plugin's setting keys, so a body is only
-- reachable through the id in the index. Under the GUIDs this used, losing the
-- index orphaned every body permanently — unreadable, undeletable, and sharing
-- the store with the OAuth tokens and every pref. A bounded key space can be
-- swept. See freeSlot and reclaimSlots.
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
-- SetSetting writes to a local JSON file with no documented ceiling, and the
-- same store holds the OAuth tokens and every pref — so what a session costs is
-- not only its own. A session carrying a few `cat`s of large ModuleScripts is
-- megabytes, and that cost is paid on every turn. Past this the old tool results
-- are stubbed before writing: the same trade Agent makes to keep the context
-- window bounded.
--
-- Lowered from 400000. That number was a TRIGGER and not a ceiling: one stubbing
-- pass keeps KEEP_RESULTS results, and at Agent's MODEL_RESULT_CHARS apiece
-- those alone are half a megabyte, so a session could sit far above the cap
-- after being "capped". The loop in save now runs the pass down until it fits,
-- which is what makes this an actual bound: 20 × this, not 20 × whatever the
-- last few tool results happened to weigh.
local MAX_BYTES = 150000
local KEEP_RESULTS = 5
local CLEARED = "[old tool result cleared — re-run the command if needed]"

-- `provider` is stamped on the index rather than into the saved blob, so
-- there is no stored format to migrate: an entry written before this simply
-- has none, and is read as Claude's, which is what it was.
--
-- It is load-bearing, not bookkeeping. A conversation is shaped by whoever
-- produced it, down to thinking-block signatures that only the issuing provider
-- can decrypt, so replaying one into the other is rejected by the API — or
-- worse, quietly accepted with the reasoning stripped.
type Entry = { id: string, title: string, place: number, updated: number, provider: string? }

-- `Provider.id` is read at CALL time, never captured here: main.luau requires
-- this module before it calls Provider.Initialize, so a copy taken now would be
-- the default rather than the saved one, and would never follow a switch.
local Provider = require(script.Parent.Parent:WaitForChild("agent"):WaitForChild("Provider"))

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

local function entryFor(id: string): Entry?
	for _, entry in ipairs(index) do
		if entry.id == id then return entry end
	end
	return nil
end

-- Session ids are SLOT NUMBERS, "1".."MAX_SESSIONS", not GUIDs.
--
-- Roblox gives no way to list a plugin's setting keys: GetSetting takes one key
-- and there is no enumerator. So a body is only ever reachable through the id
-- written in the index, which under GUIDs made the index a single point of
-- failure with no recovery — lose it and every `cc_session_<guid>` in the store
-- was unreachable AND unremovable, for the life of the install, with up to
-- twenty more added every time the cap cycled. They sat in the same store as the
-- auth tokens and the prefs.
--
-- A bounded key space is probeable, which is the whole fix: reclaimSlots below
-- can find a body the index no longer names, because there are only ever
-- MAX_SESSIONS places for one to be.
--
-- Entries written before this carry GUID ids and keep working — the key is
-- KEY_PREFIX .. id either way. They occupy no slot and age out through the
-- normal cap. Their bodies are deliberately NOT migrated: moving up to twenty
-- multi-hundred-KB values on the frame the plugin opens is exactly the stall
-- this codebase has been removing. The orphans an old install already has stay
-- orphaned, because nothing can name them.
local function freeSlot(): string?
	for slot = 1, MAX_SESSIONS do
		local id = tostring(slot)
		if not entryFor(id) then
			return id
		end
	end
	return nil
end

-- A slot for a new session, evicting the oldest when every one is taken. That
-- eviction already happened, on the next save; doing it here moves it to the
-- click that caused it, where the drawer redraw makes it visible.
local function nextId(): string
	local slot = freeSlot()
	if slot then
		return slot
	end
	table.sort(index, function(a, b) return a.updated > b.updated end)
	local dropped = table.remove(index) :: Entry
	pluginRef:SetSetting(KEY_PREFIX .. dropped.id, nil)
	persistIndex()
	-- Dropping any entry frees a slot unless the one dropped was a GUID, and a
	-- GUID entry means fewer than MAX_SESSIONS slots were taken, so freeSlot
	-- would not have returned nil above. The fallback is belt and braces.
	return freeSlot() or dropped.id
end

-- Delete any body the index no longer names. Only reachable at all because the
-- ids are slots; a GUID orphan cannot be found by anything, ever.
--
-- Runs at startup, where the index has just been read: a slot holding a body
-- with no entry is one whose entry was lost, and a conversation with no entry
-- has no title, no row and no way to be opened. Reclaiming it is the only thing
-- left that can be done with it. Slots above MAX_SESSIONS are not swept, so
-- LOWERING that constant strands whatever sat above the new value.
local function reclaimSlots(): number
	local reclaimed = 0
	for slot = 1, MAX_SESSIONS do
		local id = tostring(slot)
		if pluginRef:GetSetting(KEY_PREFIX .. id) ~= nil and not entryFor(id) then
			pluginRef:SetSetting(KEY_PREFIX .. id, nil)
			reclaimed += 1
		end
	end
	return reclaimed
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
	local reclaimed = reclaimSlots()
	if reclaimed > 0 then
		-- Worth saying out loud rather than doing quietly: it means the index was
		-- lost at some point, which is the failure this whole scheme exists for.
		warn(string.format("[agent] reclaimed %d orphaned session slot(s)", reclaimed))
	end
	setCurrent(nextId())
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
local function stubOldResults(conversation: { any }, keep: number): { any }
	local total = 0
	for _, message in ipairs(conversation) do
		if type(message.content) == "table" then
			for _, block in ipairs(message.content) do
				if block.type == "tool_result" then total += 1 end
			end
		end
	end
	local cutoff = total - keep
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
	-- The most stubbing could possibly reclaim, worked out before paying to find
	-- out. The loop below re-clones and re-encodes the WHOLE conversation once
	-- per pass, so six futile passes cost six copies of it and six multi-megabyte
	-- strings — per save, and a save runs after every tool batch.
	--
	-- It is futile whenever results are not where the size is. A session that is
	-- mostly thinking blocks and `write` payloads has nothing here to stub, and
	-- both of those are out of reach on purpose: the thinking a turn is owed
	-- back, and the record of what a write changed. Measured on a real 2 MB
	-- session — 563 results holding 35 kB between them against 1.7 MB of thinking
	-- and tool_use — stubbing every one reclaimed about 5 kB, six times over, and
	-- the full encode was written anyway.
	--
	-- A JSON-escaped string is never longer than 6 bytes per source byte (\u00XX
	-- is the longest escape there is), so 6x the raw content is a ceiling on what
	-- the encoding can shrink by. Over it, no `keep` can reach the cap and the
	-- loop is skipped; under it, nothing changes and it runs as before.
	-- Deliberately loose — it only has to be a bound, and a loose one still
	-- catches the case that costs.
	local reclaimable = 0
	if #json > MAX_BYTES then
		for _, message in ipairs(conversation) do
			if type(message.content) == "table" then
				for _, block in ipairs(message.content) do
					if block.type == "tool_result" and type(block.content) == "string"
						and #block.content > #CLEARED then
						reclaimable += #block.content
					end
				end
			end
		end
	end
	if #json > MAX_BYTES and #json - 6 * reclaimable <= MAX_BYTES then
		-- Down until it fits, rather than one pass and hope. A single pass keeps
		-- KEEP_RESULTS results whatever they weigh, and at Agent's
		-- MODEL_RESULT_CHARS apiece that is half a megabyte on its own — so the
		-- cap used to be a trigger, not a ceiling, and the store had no bound at
		-- all. Bounded at KEEP_RESULTS + 1 encodes, and only ever on a session
		-- already over the cap.
		--
		-- keep = 0 stubs every result. If even that is over, it is written anyway:
		-- what is left is the conversation itself, and dropping that to hit a
		-- number would lose the thing being saved.
		for keep = KEEP_RESULTS, 0, -1 do
			json = HttpService:JSONEncode(stubOldResults(conversation, keep))
			if #json <= MAX_BYTES then break end
		end
	end
	pluginRef:SetSetting(KEY_PREFIX .. currentId, json)

	local entry = entryFor(currentId)
	if not entry then
		entry = { id = currentId, title = "", place = game.PlaceId, updated = 0 }
		table.insert(index, entry :: Entry)
	end
	-- Stamped on every save, not only at creation: /clear empties a session in
	-- place, so the provider has to follow whatever produced the messages NOW.
	entry.provider = Provider.id
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
-- Thinking blocks are drawn, collapsed. They used to be skipped on the grounds
-- that reasoning is worth reading live and not after the fact, which stopped
-- being true the moment Find started searching it: a hit you can count but
-- cannot open is worse than no hit. A collapsed drawer is a header button and a
-- hidden label, and the tail cap below bounds how many of them exist.
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

-- Peeking
-- Opening another session mid-turn does NOT switch: Agent keeps the conversation
-- it is working on, `currentId` does not move, and the turn still lands in the
-- session that asked for it. All that changes is what is on screen, and the
-- running turn's blocks are parked in `previewHolder` rather than destroyed, so
-- coming back shows everything that arrived while you were away.
--
-- Starting a session, deleting one or clearing still need Agent, so those stay
-- blocked for the length of a turn.
local previewHolder: Frame? = nil
local previewId = ""

local function blockedByTurn(): boolean
	if not Agent.isBusy() then return false end
	Console.appendLine("Finish or stop the current turn first.", "error")
	return true
end

-- Drops the parked blocks instead of moving them back on screen. Every caller of
-- this one is about to clear the console anyway.
local function dropPeek()
	local holder = previewHolder
	if not holder then return end
	previewHolder = nil
	previewId = ""
	Console.discard(holder)
end

-- Back to the session that is actually running.
function Sessions.endPeek()
	local holder = previewHolder
	if not holder then return end
	previewHolder = nil
	previewId = ""
	Console.reattach(holder)
	if refreshList then refreshList() end
end

-- Forward-declared: replayInto's paging link calls back into the wrapper, and a
-- local named after its own use site is a nil global, not that local.
local replay: ({ any }) -> ()

local function replayInto(conversation: { any })
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
	-- The link belongs to no message; only the loop below anchors anything.
	Console.setMessage(0)
	if first > 1 then
		Console.appendLink(
			string.format("↑ Load %d earlier messages (%d older)",
				math.min(REPLAY_MESSAGES, first - 1), first - 1),
			function()
				-- Redrawing would destroy the bubble a running turn is streaming
				-- into — unless there is a peek on, in which case that turn is
				-- already parked off screen and the visible frame is ours to redraw.
				if previewHolder == nil and blockedByTurn() then return end
				shown += REPLAY_MESSAGES
				Console.clear()
				replay(conversation)
				-- The reader clicked the thing at the top, so leave them at the top
				-- looking at the messages they just pulled up, not back at the newest.
				Console.scrollToTop()
			end)
	end

	for index = first, #conversation do
		-- What Find scrolls back to. Set per message rather than per block: a
		-- tool call and the reply above it are one message and one destination.
		Console.setMessage(index)
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
			-- Above the reply, which is where the live view puts it too.
			for _, block in ipairs(content) do
				if block.type == "thinking" and type(block.thinking) == "string"
					and block.thinking ~= "" then
					local drawer = Console.createThinking()
					drawer.append(block.thinking)
					-- Immediately: nothing is streaming, and an unfinished drawer
					-- spins forever.
					drawer.finish()
				end
			end
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
	Console.setMessage(0)
end

replay = function(conversation: { any })
	-- Uncapped, because `shown` is already the cap here. The console trims itself
	-- as a LIVE session grows, and trimming underneath a replay would eat its
	-- oldest blocks — which are the ones the paging link just pulled up, and for
	-- a Find jump are the message being jumped to.
	Console.uncapped(function()
		Console.onScreen(function() replayInto(conversation) end)
	end)
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
	-- Refused rather than half-loaded. The alternative is a conversation that
	-- looks fine on screen and is rejected by the API on the next turn, with an
	-- error naming a signature rather than the session that carried it.
	local entry = entryFor(id)
	local owner = (entry and entry.provider) or "anthropic"
	if owner ~= Provider.id then
		Console.appendLine(string.format(
			"That session was made with %s. Switch back with /provider %s to open it.",
			Provider.label(owner), owner), "error")
		return
	end

	local conversation = decode(pluginRef:GetSetting(KEY_PREFIX .. id))
	if type(conversation) ~= "table" then
		Console.appendLine("That session could not be loaded.", "error")
		return
	end
	repairInputs(conversation)

	if Agent.isBusy() then
		if not previewHolder then previewHolder = Console.detach() end
		previewId = id
		Console.clear()
		shown = REPLAY_MESSAGES
		replay(conversation)
		local running = entryFor(currentId)
		Console.onScreen(function()
			Console.appendLine(string.format(
				"Viewing only — \"%s\" is still working. Click it to come back.",
				running and running.title or "the running session"), "system")
		end)
		if refreshList then refreshList() end
		return
	end

	-- Not a peek any more, and what it parked is about to be cleared off the
	-- screen regardless.
	dropPeek()

	setCurrent(id)
	Console.clear()
	Agent.restore(conversation)
	shown = REPLAY_MESSAGES
	replay(conversation)
	Console.appendLine(string.format("Restored session — %d messages.", #conversation), "system")
end

-- Find asks for a message by its index and this makes sure it is on screen
-- before the console scrolls to it. Only a REPLAY can be short: a live turn
-- draws everything as it arrives, so the usual case is the first jump landing
-- and nothing being redrawn at all.
function Sessions.reveal(index: number)
	-- You asked to be taken to a message in YOUR conversation, so come back from
	-- whatever you were reading first.
	Sessions.endPeek()
	if Console.jumpToMessage(index) then return end

	if Agent.isBusy() then
		-- Redrawing would destroy the bubble the turn is streaming into.
		Console.appendLine(
			"That message is further back than the view — finish the turn to load it.", "system")
		return
	end
	-- The same paging the link at the top of a truncated replay does, sized to
	-- reach the message in one go rather than a page at a time, with a page of
	-- lead-in above it so it does not land against the top edge.
	local conversation = Agent.conversation()
	shown = math.max(shown, #conversation - index + 1 + REPLAY_MESSAGES)
	Console.clear()
	replay(conversation)
	Console.jumpToMessage(index)
end

function Sessions.new()
	if blockedByTurn() then return end
	-- Reachable with a peek still up: the turn ended while the reader was
	-- looking elsewhere, and nothing has put the view back yet. Without this the
	-- sink stays pointed at the holder and the fresh session draws off screen.
	dropPeek()
	-- The current session is already on disk: save() runs at the end of every
	-- turn, so there is nothing to flush before letting go of it.
	setCurrent(nextId())
	Console.clear()
	Agent.reset()
end

function Sessions.delete(id: string)
	if id == currentId and blockedByTurn() then return end
	-- Deleting the one you are peeking at would leave a conversation on screen
	-- that no longer exists anywhere.
	if id == previewId then Sessions.endPeek() end
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
-- The most recent session for this place THAT THIS PROVIDER MADE. Skipping the
-- others rather than refusing on the first one: reopening the plugin after a
-- provider switch should land somewhere usable, not print an error about a
-- session nobody asked for.
function Sessions.restoreLast()
	for _, entry in ipairs(index) do
		if entry.place == game.PlaceId
			and ((entry.provider or "anthropic") == Provider.id) then
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
	-- each, on a keystroke; the find panel searches one once it is open.
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
				-- The highlight follows what is on SCREEN, which during a peek is
				-- the previewed session and not the one still running.
				local viewing = if previewId ~= "" then previewId else currentId
				local active = entry.id == viewing
				local running = previewId ~= "" and entry.id == currentId
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
					TextColor3 = if running then Theme.ACCENT else Theme.TEXT_LO,
					TextXAlignment = Enum.TextXAlignment.Left,
					-- The peek outlives the turn: the reader is still looking
					-- elsewhere after it lands, so the row stops claiming to be
					-- working but keeps saying how to get back.
					Text = if running
						then (if Agent.isBusy() then "working — click to come back" else "click to come back")
						else ago(entry.updated),
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
					if id == currentId and previewHolder then
						Sessions.endPeek()
					elseif id ~= currentId and id ~= previewId then
						Sessions.load(id)
					end
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

	local stubbed = stubOldResults(conversation, KEEP_RESULTS)
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

	-- Slots, against a fake store: this is the half that used to be impossible.
	-- Everything here writes through pluginRef, so it is swapped for a table and
	-- the real plugin settings are never touched.
	local realPlugin, realIndex = pluginRef, index
	local store: { [string]: any } = {}
	pluginRef = {
		GetSetting = function(_, key) return store[key] end,
		SetSetting = function(_, key, value) store[key] = value end,
	} :: any
	index = {}

	local slotOk, slotErr = pcall(function()
		if freeSlot() ~= "1" then error("an empty index did not offer slot 1", 0) end
		-- A pre-slot GUID entry occupies no slot, which is what lets an old
		-- install keep its sessions without a migration.
		index = { { id = "abc-guid", title = "old", place = 0, updated = 1 } :: Entry }
		if freeSlot() ~= "1" then error("a GUID entry consumed a slot", 0) end
		-- Lowest free, not next: a deleted session's slot is reusable.
		index = {
			{ id = "1", title = "a", place = 0, updated = 3 } :: Entry,
			{ id = "3", title = "c", place = 0, updated = 1 } :: Entry,
		}
		if freeSlot() ~= "2" then error("freeSlot did not reuse the gap", 0) end
		-- Full: the oldest goes, and its body with it.
		index = {}
		for slot = 1, MAX_SESSIONS do
			index[slot] = { id = tostring(slot), title = "s", place = 0, updated = slot } :: Entry
			store[KEY_PREFIX .. slot] = "body"
		end
		if freeSlot() ~= nil then error("freeSlot found a slot in a full index", 0) end
		local taken = nextId()
		if taken ~= "1" then error("nextId evicted something other than the oldest: " .. taken, 0) end
		if store[KEY_PREFIX .. "1"] ~= nil then
			error("nextId dropped the entry but left its body behind", 0)
		end
		if #index ~= MAX_SESSIONS - 1 then error("nextId did not drop exactly one entry", 0) end

		-- The reclaim. A body whose entry is gone is unreachable by every read,
		-- and before slots it was also impossible to delete.
		store[KEY_PREFIX .. "1"] = "orphan"
		if reclaimSlots() ~= 1 then error("reclaimSlots missed an unreferenced body", 0) end
		if store[KEY_PREFIX .. "1"] ~= nil then error("reclaimSlots left the orphan", 0) end
		if reclaimSlots() ~= 0 then error("reclaimSlots deleted a body the index names", 0) end
	end)

	pluginRef, index = realPlugin, realIndex
	if not slotOk then
		return false, tostring(slotErr)
	end

	return true
end

return Sessions
