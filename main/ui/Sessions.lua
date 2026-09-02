-- Sessions.luau: saved conversations, and the sidebar that switches between them.
--
-- The conversation IS the session: everything else on screen is derived from it,
-- so persisting `Agent.conversation()` and replaying it through the Console's
-- normal appenders is the whole feature. Nothing new renders here.
--
-- Storage is Instances under ServerStorage, one folder per session:
--
--   ServerStorage/AgentSessions/<guid>/   attributes: title, updated, provider,
--                                         chunks
--     1, 2, 3 ...                         StringValue, <= CHUNK_BYTES each
--
-- It used to be plugin:SetSetting, and that looked like a key-value store while
-- being one JSON file per plugin — shared by every locally-installed plugin,
-- with no partial write. Setting one key re-serialised all of it. Measured on a
-- real install: 15.4 MB across eighteen conversations, rewritten after every
-- tool batch. That is what made loading the plugin, opening the settings panel
-- and switching sessions stall, and the size caps could not fix it: the only
-- thing they knew how to shrink was tool_result content, 2% of a session.
--
-- A folder costs only its own session to write, and only the session you open to
-- read — which is what makes the list cheap: it is built from attributes and
-- never touches a body. The slot ids this used are gone with it, along with
-- freeSlot, nextId's eviction and reclaimSlots: those existed only because
-- setting keys cannot be enumerated, and folder children can.
--
-- The price is that ServerStorage is part of the PLACE. Sessions persist on
-- Ctrl+S rather than immediately, they ship when the place is published, they
-- replicate in Team Create, and writing one marks the place dirty. cc_active
-- covers the first of those; see the mirror in save().
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

-- Legacy keys. Read once at Initialize to clear what the old scheme left in the
-- shared settings file, then never written again.
local KEY_INDEX = "cc_sessions"
local KEY_PREFIX = "cc_session_"
-- The one key still in use, see the mirror in save().
local KEY_ACTIVE = "cc_active"

-- Sessions are Instances under ServerStorage, not plugin settings.
--
-- SetSetting looks like a key-value store and is not: Roblox backs ALL of a
-- plugin's settings with ONE JSON file, shared by every locally-installed
-- plugin, and there is no partial write — setting any key re-serialises the
-- whole thing. Measured on a real install: 15.4 MB across eighteen
-- conversations, in a file that also held another plugin's settings. save() runs
-- after every tool batch, so a twenty-tool sweep was twenty full rewrites. That
-- is what made opening the settings panel, switching sessions and loading the
-- plugin stall, and no cap could fix it: MAX_BYTES only knew how to shrink
-- tool_result content, which is 2% of a session — the rest is thinking blocks
-- and `write` payloads, and neither is reachable from here.
--
-- A folder per session costs only that session to write, and only the one you
-- open to read.
--
-- The price is that ServerStorage is part of the PLACE. Sessions persist on
-- Ctrl+S rather than immediately, they are included when the place is published,
-- they replicate in Team Create, and writing one marks the place dirty. Git.lua
-- keeps the GitHub token out of the DataModel for exactly that reason; the
-- difference is that a conversation is the reader's own content rather than a
-- credential. KEY_ACTIVE covers the first of those.
local FOLDER_NAME = "AgentSessions"

-- GetService, never FindFirstChild: the two return different objects the moment
-- something else in `game` shares the name. Shell.lua:1556 documents the same
-- trap for the same service.
local ServerStorage = game:GetService("ServerStorage")

-- StringValue.Value refuses at 200,000 characters — the same ceiling .Source has,
-- and the same error — so a conversation is split across several.
local CHUNK_BYTES = 190000

-- ponytail: no size limit and no eviction, deliberately. A lazy read costs only
-- the session opened, so size no longer shows up per operation. Ceiling: the
-- place file grows for as long as sessions are kept, and saving it slows with
-- them. Upgrade path is eviction by the `updated` attribute until a total fits.

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

local function entryFor(id: string): Entry?
	for _, entry in ipairs(index) do
		if entry.id == id then return entry end
	end
	return nil
end

-- The sessions folder, made on first WRITE only. A place that never talks to the
-- agent gets no folder, and a read has no business creating one.
local function sessionsFolder(create: boolean?): Instance?
	local folder = ServerStorage:FindFirstChild(FOLDER_NAME)
	if not folder and create then
		local made = Instance.new("Folder")
		made.Name = FOLDER_NAME
		made.Parent = ServerStorage
		folder = made
	end
	return folder
end

-- Split for StringValue, on a CHARACTER boundary rather than a byte one.
--
-- JSONEncode emits raw multi-byte UTF-8 — every em dash in this codebase is
-- three bytes — and on real sessions one boundary in seventy-three landed
-- inside a codepoint. A plain :sub() there leaves two chunks that are each
-- invalid UTF-8, which is the kind of corruption that appears once in fifty
-- saves and cannot be traced back to the save that caused it.
--
-- utf8.offset(s, 0, k) is the start of the character CONTAINING byte k, so
-- asking about the byte just past the cut moves the cut back onto a boundary.
-- The `start > i` guard is for a single character longer than the chunk, which
-- cannot happen with 190000 but costs one comparison to rule out.
local function splitChunks(text: string): { string }
	local out: { string } = {}
	local i = 1
	while i <= #text do
		local stop = math.min(i + CHUNK_BYTES - 1, #text)
		if stop < #text then
			local start = utf8.offset(text, 0, stop + 1)
			if start and start > i then stop = start - 1 end
		end
		out[#out + 1] = text:sub(i, stop)
		i = stop + 1
	end
	return out
end

-- Chunks are REUSED rather than destroyed and remade: a save that rewrites the
-- same values touches no instance tree, where a destroy/create pair churns the
-- Explorer and the undo stream on every turn.
-- Bytes, not text: splitChunks backs each cut onto a UTF-8 character boundary,
-- which is meaningless on compressed data.
local function splitBinary(text: string): { string }
	local out: { string } = {}
	local i = 1
	while i <= #text do
		local stop = math.min(i + CHUNK_BYTES - 1, #text)
		out[#out + 1] = text:sub(i, stop)
		i = stop + 1
	end
	return out
end

local function writeBody(session: Instance, text: string, binary: boolean?)
	local parts = if binary then splitBinary(text) else splitChunks(text)
	for n, part in ipairs(parts) do
		local name = tostring(n)
		local existing = session:FindFirstChild(name)
		if existing and not existing:IsA("StringValue") then
			existing:Destroy()
			existing = nil
		end
		local value = existing :: any
		if value then
			-- UNCHANGED chunks are left alone. A conversation grows by appending, so
			-- of eleven chunks in a 2 MB session exactly one differs from the last
			-- save — and this runs after every tool batch. Assigning all eleven
			-- rewrote 2 MB to change 190 kB of it, and every write marks the place
			-- dirty. Same defect as Settings.setSystem and Provider.use, one layer
			-- down: the cheapest write is the one not made.
			if value.Value ~= part then
				value.Value = part
			end
		else
			value = Instance.new("StringValue")
			value.Name = name
			value.Value = part
			value.Parent = session
		end
	end
	-- The count, written BEFORE the leftovers go. readBody reads exactly this
	-- many and ignores everything else, so a write that dies partway through, or
	-- a stray StringValue dropped into the folder by hand, cannot be
	-- concatenated onto the end of a conversation.
	--
	-- SetSetting swapped one string and was atomic for free. N instance writes
	-- are not, and this is the cheapest thing that stops a torn one decoding as
	-- garbage: it degrades to "could not be loaded", which is the truth.
	session:SetAttribute("chunks", #parts)
	-- A conversation that SHRANK leaves chunks numbered past the new end.
	-- StringValues with numeric names ONLY: this folder is visible in the
	-- Explorer, and anything else in it belongs to whoever put it there.
	for _, child in ipairs(session:GetChildren()) do
		local n = tonumber(child.Name)
		if n and n > #parts and child:IsA("StringValue") then child:Destroy() end
	end
end

-- Indexed by the chunk's number, never appended: GetChildren is insertion order,
-- which stops being chunk order the first time a session is rewritten.
--
-- A missing chunk (deleted by hand in the Explorer) leaves a hole, and
-- table.concat stops at it rather than splicing the tail on — so the result
-- fails to decode and the session reports as unloadable, which is the truth.
local function readBody(session: Instance): string
	local count = tonumber(session:GetAttribute("chunks"))
	local parts: { string } = {}
	for _, child in ipairs(session:GetChildren()) do
		local n = tonumber(child.Name)
		if n and child:IsA("StringValue") and (count == nil or n <= count) then
			parts[n] = child.Value
		end
	end
	-- A hole means a torn write or a chunk deleted by hand. Returning the prefix
	-- would hand JSONDecode a truncated document; returning nothing lets the
	-- caller say the session cannot be loaded, which is what has happened.
	if count then
		for n = 1, count do
			if parts[n] == nil then return "" end
		end
	end
	return table.concat(parts)
end

-- Compression, for sessions that are no longer the open one.
--
-- COLD ONLY, and that is forced rather than tidy. Compressed bytes have no
-- stable prefix: one new message changes every one of them, so compressing the
-- live session would undo the skip in writeBody and rewrite the whole thing on
-- every tool batch. Plain text while a session is open, compressed once it is
-- left. The session you use every day therefore never compresses, which is the
-- right outcome — it is the other nineteen that cost space.
--
-- EncodingService shipped 2026-09-01 and is not in the API dump yet, so it is
-- fetched through a pcall and everything here degrades to plain text without it.
local EncodingService: any = nil
do
	local ok, service = pcall(game.GetService, game, "EncodingService")
	if ok then EncodingService = service end
end

-- Level 3. Measured on a real 1.9 MB session: level 1 is 2.03x in 5.6 ms, level
-- 3 is 2.20x in 7.8 ms, level 19 is 2.29x in 574 ms, and level 22 comes out
-- WORSE than level 15. Past 3 the ratio is flat and the clock is not, and 8 ms
-- on a session switch is not felt.
local COMPRESS_LEVEL = 3

-- Compressed bytes are not valid UTF-8, and whether a StringValue carries them
-- through a place save intact is UNVERIFIED: binary .rbxl should, .rbxlx cannot
-- represent them at all and people save as XML for git. Base64 is 4/3 the size
-- and raises no such question, so it is the default.
--
-- Flip to true once the byte probe in the plan prints SURVIVED: 1.65x becomes
-- 2.20x. Sessions already written stay readable either way — the form is
-- recorded per folder in the `compressed` attribute, not inferred from this.
local RAW_BYTES = false

local function packBody(text: string): (string?, string?)
	if not EncodingService then return nil, nil end
	local ok, packed = pcall(function()
		local out = EncodingService:CompressBuffer(
			buffer.fromstring(text), Enum.CompressionAlgorithm.Zstd, COMPRESS_LEVEL)
		if not RAW_BYTES then
			out = EncodingService:Base64Encode(out)
		end
		return buffer.tostring(out)
	end)
	if not ok then return nil, nil end
	return packed, (if RAW_BYTES then "zstd" else "zstd-b64")
end

-- `form` comes off the folder rather than from RAW_BYTES, so flipping that
-- constant cannot orphan sessions written under the other one.
local function unpackBody(body: string, form: string): string?
	if not EncodingService then return nil end
	local ok, text = pcall(function()
		local packed = buffer.fromstring(body)
		if form == "zstd-b64" then
			packed = EncodingService:Base64Decode(packed)
		end
		return buffer.tostring(
			EncodingService:DecompressBuffer(packed, Enum.CompressionAlgorithm.Zstd))
	end)
	return ok and text or nil
end

-- Compress a session in place. Skipped when it is already cold, when the service
-- is missing, and when compressing would not actually save anything.
local function compressSession(session: Instance)
	if not EncodingService then return end
	if session:GetAttribute("compressed") ~= nil then return end
	local text = readBody(session)
	if text == "" then return end
	local packed, form = packBody(text)
	if not packed or not form or #packed >= #text then return end
	writeBody(session, packed, true)
	session:SetAttribute("compressed", form)
end

-- The body as JSON text, whichever form it is stored in.
local function loadBody(session: Instance): string
	local body = readBody(session)
	local form = session:GetAttribute("compressed")
	if type(form) == "string" and form ~= "" then
		return unpackBody(body, form) or ""
	end
	return body
end

-- The index IS the folder. Listing sessions reads attributes and never a body,
-- which is the whole point of the move.
--
-- `place` is stamped as the CURRENT place rather than stored: the folder lives
-- in this place's file, so everything in it belongs to this place by
-- construction. draw() and restoreLast() both filter on it and neither needs
-- changing.
local function rebuildIndex()
	index = {}
	local folder = sessionsFolder()
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Folder") then
				index[#index + 1] = {
					id = child.Name,
					-- Never nil: draw() calls entry.title:lower().
					title = tostring(child:GetAttribute("title") or ""),
					place = game.PlaceId,
					updated = tonumber(child:GetAttribute("updated")) or 0,
					provider = child:GetAttribute("provider") :: string?,
				}
			end
		end
	end
	-- Newest first. restoreLast takes the FIRST match and the drawer reads top
	-- down; save() used to hold this order by sorting after every write.
	table.sort(index, function(a, b) return a.updated > b.updated end)
end

-- A GUID again, and the reason the slot scheme existed is gone with it: setting
-- keys could not be enumerated, so a bounded key space was the only way to find
-- a body the index no longer named. Folder children enumerate, so freeSlot,
-- nextId's eviction and reclaimSlots all went with it — an orphan is now just
-- a folder you can see and delete in the Explorer.
local function nextId(): string
	return HttpService:GenerateGUID(false)
end

-- The active row is drawn differently, so every change of session has to redraw
-- the list or the highlight stays on the one you just left. Going through a
-- setter is what keeps that true for all three ways currentId moves, switch,
-- new, delete, rather than only the one that remembered to refresh. Defined up
-- here because Initialize is the first caller and a `local function` is not in
-- scope above its own definition.
local function setCurrent(id: string)
	-- The session being LEFT goes cold, and this is the only funnel every change
	-- of session runs through, so it is the only place that has to know.
	if currentId ~= "" and currentId ~= id then
		local folder = sessionsFolder()
		local leaving = folder and folder:FindFirstChild(currentId)
		if leaving and leaving:IsA("Folder") then
			compressSession(leaving)
		end
	end
	currentId = id
	if refreshList then refreshList() end
end

function Sessions.Initialize(p: Plugin)
	pluginRef = p
	rebuildIndex()
	-- One-time clean-up of the old scheme. Nothing is migrated: the bodies were
	-- whole conversations in the shared settings file, which is the problem being
	-- removed, and reading twenty of them back out on the frame the plugin opens
	-- would be the stall this change exists to delete.
	--
	-- Gated on the index key so it costs nothing on every later launch, and each
	-- delete is skipped unless that key is really there — a SetSetting is a
	-- whole-store write, and there is no reason to pay for one to remove nothing.
	if p:GetSetting(KEY_INDEX) ~= nil then
		local stale = decode(p:GetSetting(KEY_INDEX))
		if type(stale) == "table" then
			for _, entry in ipairs(stale) do
				if type(entry) == "table" and type(entry.id) == "string"
					and p:GetSetting(KEY_PREFIX .. entry.id) ~= nil then
					p:SetSetting(KEY_PREFIX .. entry.id, nil)
				end
			end
		end
		-- The slot key space, for bodies whose entry was already lost.
		for slot = 1, 20 do
			if p:GetSetting(KEY_PREFIX .. tostring(slot)) ~= nil then
				p:SetSetting(KEY_PREFIX .. tostring(slot), nil)
			end
		end
		p:SetSetting(KEY_INDEX, nil)
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
-- The MIRROR's ceiling, not the archive's. ServerStorage is uncapped by design;
-- this bounds only the crash copy that goes into the shared settings file, which
-- is the file whose size caused all of this. Stubbing old tool results is the
-- trade this module already made, for exactly this reason.
local MIRROR_BYTES = 150000
local KEEP_RESULTS = 5
local CLEARED = "[old tool result cleared — re-run the command if needed]"

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

	local folder = sessionsFolder(true) :: Instance
	local existing = folder:FindFirstChild(currentId)
	if existing and not existing:IsA("Folder") then
		existing:Destroy()
		existing = nil
	end
	local session = existing
	if not session then
		local made = Instance.new("Folder")
		made.Name = currentId
		made.Parent = folder
		session = made
	end
	writeBody(session :: Instance, json)
	-- Reopened and written to again, so it is warm: the chunks above are plain
	-- text now and the attribute has to stop claiming otherwise. Plain text is
	-- always LONGER than the compressed form it replaces, so writeBody's own
	-- sweep has already removed every leftover binary chunk.
	;(session :: Instance):SetAttribute("compressed", nil)
	-- Retitled and re-stamped on EVERY save rather than once at creation: /clear
	-- empties a session in place, so the title and the provider both have to
	-- follow what is in it now.
	local target = session :: Instance
	target:SetAttribute("title", titleOf(conversation) or (os.date("%b %d, %H:%M") :: string))
	-- ONE timestamp for the folder and the mirror below. Two os.time() calls can
	-- straddle a second, and restoreLast compares them: a mirror a second newer
	-- than the folder written beside it would win the tiebreak and restore the
	-- stubbed copy over the complete one.
	local now = os.time()
	target:SetAttribute("updated", now)
	target:SetAttribute("provider", Provider.id)
	rebuildIndex()

	-- The crash copy. ServerStorage only reaches disk when the PLACE is saved, so
	-- a place closed or crashed without a Ctrl+S loses everything since the last
	-- one — including, on the first turn of a session, a message the reader would
	-- have to retype. This runs on every save for that reason: Agent fires the
	-- checkpoint as the message goes IN, which is the write that protects it.
	--
	-- Stubbed, unlike the archive, and that is what makes running it every time
	-- affordable: a SetSetting re-serialises the whole settings file, so what
	-- goes there has to stay small. Bounded at MIRROR_BYTES the file stays in the
	-- low hundreds of KB, where the same write against the old 15 MB store was
	-- the stall this module was rewritten to remove.
	local body = json
	if #body > MIRROR_BYTES then
		for keep = KEEP_RESULTS, 0, -1 do
			body = HttpService:JSONEncode(stubOldResults(conversation, keep))
			if #body <= MIRROR_BYTES then break end
		end
	end
	pcall(function()
		pluginRef:SetSetting(KEY_ACTIVE, HttpService:JSONEncode({
			id = currentId,
			-- Stamped because a setting key is global to the plugin where a folder
			-- is not: without these, recovery would restore this conversation into
			-- whatever place and provider happened to open next.
			place = game.PlaceId,
			provider = Provider.id,
			updated = now,
			body = body,
		}))
	end)

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

	local folder = sessionsFolder()
	local session = folder and folder:FindFirstChild(id)
	local conversation = if session and session:IsA("Folder")
		then decode(loadBody(session)) else nil
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
	local folder = sessionsFolder()
	local session = folder and folder:FindFirstChild(id)
	if session then session:Destroy() end
	-- The mirror too, or /clear does not clear. Commands.lua says it outright:
	-- "leaving the saved copy behind would have the next open restore what was
	-- just cleared" — and the crash copy is a saved copy.
	local saved = decode(pluginRef:GetSetting(KEY_ACTIVE))
	if type(saved) == "table" and saved.id == id then
		pcall(function() pluginRef:SetSetting(KEY_ACTIVE, nil) end)
	end
	rebuildIndex()
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
	-- The folders are the record, and Initialize is not the last word on them:
	-- a place reload, or a folder deleted by hand in the Explorer, both land
	-- between then and here.
	rebuildIndex()
	local newest: Entry? = nil
	for _, entry in ipairs(index) do
		if entry.place == game.PlaceId
			and ((entry.provider or "anthropic") == Provider.id) then
			newest = entry
			break
		end
	end

	-- The crash copy, weighed by TIME rather than by existence.
	--
	-- Preferring the folder outright loses the exact case the mirror exists for:
	-- a place last saved days ago still HAS folders, so an hour of unsaved work
	-- sitting in the mirror would never be read — and the next save would
	-- overwrite it. Whichever is newer wins.
	--
	-- place and provider are checked because a setting key is global to the
	-- plugin where a folder is not: without them this restores one place's
	-- conversation into another, which is the thing the place filter exists to
	-- stop. ponytail: an unpublished local place reports PlaceId 0, so two of
	-- them are indistinguishable here. Upgrade path is a marker instance in the
	-- place, the day that turns up as a real confusion rather than a hypothetical.
	local saved = decode(pluginRef:GetSetting(KEY_ACTIVE))
	if type(saved) == "table" and type(saved.body) == "string"
		and type(saved.id) == "string"
		and saved.place == game.PlaceId
		and (saved.provider or "anthropic") == Provider.id
		and (newest == nil or (tonumber(saved.updated) or 0) > newest.updated) then
		local conversation = decode(saved.body)
		if type(conversation) == "table" then
			repairInputs(conversation)
			dropPeek()
			setCurrent(saved.id)
			Console.clear()
			Agent.restore(conversation)
			shown = REPLAY_MESSAGES
			replay(conversation)
			Console.appendLine(string.format(
				"Recovered %d messages — the place was closed without saving.",
				#conversation), "system")
			return
		end
	end

	if newest then Sessions.load(newest.id) end
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
		-- Re-read the folders first. Under SetSetting `index` WAS the record and
		-- only this module could change it; now the folders are, and they sit in
		-- the Explorer where anything can rename, retitle or delete one. Drawing
		-- from a stale copy is how a row comes to point at a session that is not
		-- there, or how a cleared title reaches entry.title:lower() as nil.
		rebuildIndex()
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
	-- Chunking, against a folder that is NOT in the place. Instance.new with no
	-- Parent is the same trick as the pluginRef swap this replaces, one layer
	-- down: /selftest is one command away and must not write into ServerStorage.
	--
	-- This is the only genuinely new primitive in the module, and the only one
	-- that can corrupt silently, so it is what the test is spent on.
	local root = Instance.new("Folder")
	local chunkOk, chunkErr = pcall(function()
		local function session(): Instance
			local f = Instance.new("Folder")
			f.Parent = root
			return f
		end
		local function roundTrip(name: string, body: string)
			local f = session()
			writeBody(f, body)
			local back = readBody(f)
			if back ~= body then
				error(string.format("%s: %d bytes in, %d back", name, #body, #back), 0)
			end
		end

		roundTrip("empty", "")
		roundTrip("one short chunk", "[]")
		roundTrip("exactly one chunk", string.rep("a", CHUNK_BYTES))
		roundTrip("one past a chunk", string.rep("a", CHUNK_BYTES + 1))
		roundTrip("several chunks", string.rep("ab", CHUNK_BYTES * 2))

		-- A cut landing INSIDE a codepoint. JSONEncode emits raw multi-byte UTF-8,
		-- and on real sessions one boundary in seventy-three landed here; a plain
		-- :sub() leaves two chunks that are each invalid UTF-8.
		local wide = string.rep("\u{2014}", CHUNK_BYTES)
		roundTrip("split mid-codepoint", wide)
		local widened = session()
		writeBody(widened, wide)
		for _, child in ipairs(widened:GetChildren()) do
			if child:IsA("StringValue") and not utf8.len(child.Value) then
				error("a chunk is not valid UTF-8 on its own", 0)
			end
		end

		-- SHRINKING. Chunks numbered past the new end have to go, or the next read
		-- concatenates them onto the end of the conversation.
		local shrink = session()
		writeBody(shrink, string.rep("x", CHUNK_BYTES * 4))
		writeBody(shrink, "small")
		if readBody(shrink) ~= "small" then error("a shrunk session read back long", 0) end
		local kept = 0
		for _, child in ipairs(shrink:GetChildren()) do
			if child:IsA("StringValue") then kept += 1 end
		end
		if kept ~= 1 then error("shrinking left " .. kept .. " chunks, want 1", 0) end

		-- A stray value dropped into the folder by hand is IGNORED rather than
		-- spliced on, which is what the chunks attribute buys.
		local stray = Instance.new("StringValue")
		stray.Name = "9"
		stray.Value = "garbage"
		stray.Parent = shrink
		if readBody(shrink) ~= "small" then error("a stray chunk was concatenated in", 0) end
		local notes = Instance.new("StringValue")
		notes.Name = "notes"
		notes.Value = "hello"
		notes.Parent = shrink
		if readBody(shrink) ~= "small" then error("a non-numeric child was read as a chunk", 0) end

		-- A HOLE is a torn write. Reading the prefix would hand JSONDecode a
		-- truncated document; nothing at all is the honest answer.
		local torn = session()
		writeBody(torn, string.rep("y", CHUNK_BYTES * 3))
		local middle = torn:FindFirstChild("2")
		if middle then middle:Destroy() end
		if readBody(torn) ~= "" then error("a torn session read back as a prefix", 0) end

		-- Writing the SAME text twice must touch nothing. This is the whole point
		-- of the skip in writeBody, and a Changed counter is the only way to see
		-- it from outside: the bytes are identical either way.
		local quiet = session()
		local same = string.rep("q", CHUNK_BYTES * 2)
		writeBody(quiet, same)
		local writes = 0
		for _, child in ipairs(quiet:GetChildren()) do
			if child:IsA("StringValue") then
				child.Changed:Connect(function() writes += 1 end)
			end
		end
		writeBody(quiet, same)
		if writes ~= 0 then error("rewrote " .. writes .. " unchanged chunk(s)", 0) end
		-- ...and a real change still lands, or the skip is just a broken write.
		writeBody(quiet, string.rep("q", CHUNK_BYTES * 2 - 1) .. "z")
		if writes == 0 then error("a changed chunk was not written", 0) end

		-- Compression. With no EncodingService the whole path has to degrade to
		-- plain text rather than fail, so both branches are assertions.
		local cold = session()
		local body = string.rep('{"a":1}', 5000)
		writeBody(cold, body)
		compressSession(cold)
		if EncodingService then
			if cold:GetAttribute("compressed") == nil then
				error("compressSession left the folder uncompressed", 0)
			end
		elseif cold:GetAttribute("compressed") ~= nil then
			error("marked compressed with no EncodingService", 0)
		end
		if loadBody(cold) ~= body then error("a cold session did not round-trip", 0) end

		-- Big enough to span several chunks in the compressed form too.
		local spanning = session()
		local big = string.rep('{"k":"vvvvvvvvvv"}', 60000)
		writeBody(spanning, big)
		compressSession(spanning)
		if loadBody(spanning) ~= big then
			error("a multi-chunk cold session did not round-trip", 0)
		end

		-- A folder with no `compressed` attribute keeps reading as plain text.
		local plain = session()
		writeBody(plain, "[1,2,3]")
		if loadBody(plain) ~= "[1,2,3]" then error("a plain session did not read back", 0) end
	end)
	root:Destroy()
	if not chunkOk then
		return false, tostring(chunkErr)
	end

	return true
end

return Sessions
