--!optimize 2
-- Props.luau: property discovery via the Roblox API dump.
--
-- Roblox still has no runtime reflection API (no Instance:GetProperties()), so
-- property NAMES come from the API dump, fetched once per session. VALUES are
-- diffed against a freshly constructed instance of the same class, so `cat`
-- prints only what has actually been changed from default.
--
-- Split out of Terminal because this is the one part of the harness that does
-- network I/O and holds session-long state; keeping it next to the shell meant
-- the yielding code and the code that must never yield lived in one file.

local HttpService = game:GetService("HttpService")

local Props = {}

-- The classic recipe (setup.rbxcdn.com/versionQTStudio -> {version}-API-Dump.json)
-- is dead: it still returns 200 but the payload has been frozen since Aug 2023
-- and lists 682 classes against the current 903. The Client Tracker mirror is
-- rebuilt every deployment. Mini-API-Dump is ~2.7 MB vs ~7.1 MB for the full
-- dump, with an identical schema for everything we read here.
local DUMP_URL = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/Mini-API-Dump.json"

-- Hidden/NotScriptable can't be read from Luau at all; Deprecated and ReadOnly
-- are noise for an agent trying to understand what a builder configured.
local SKIP_TAGS: { [string]: boolean } = {
	Hidden = true,
	Deprecated = true,
	NotScriptable = true,
	ReadOnly = true,
}

local dumpClasses: { [string]: any }? = nil   -- ClassName -> dump entry
local dumpError: string? = nil
local propCache: { [string]: { string } } = {}
local defaultCache: { [string]: any } = {}     -- ClassName -> Instance | false

-- ponytail: one ~2.7 MB fetch + JSONDecode per Studio session, held resident for
-- the session along with one default Instance per class inspected. Ceiling: a
-- 1-2s stall on whichever call triggers it, which is why main preloads it in the
-- background at startup. Upgrade path if that ever matters: pre-derive the
-- ClassName -> property-name map offline (87 KB for all 903 classes) and ship it
-- as a generated ModuleScript instead of fetching at runtime.
local function loadDump(): boolean
	if dumpClasses then return true end
	if dumpError then return false end

	local ok, body = pcall(function()
		return HttpService:GetAsync(DUMP_URL)
	end)
	if not ok then
		-- These three strings reach the model through cat's
		-- "(properties unavailable: %s)" wrapper, so they name what the caller
		-- lost rather than the mechanism that lost it. "API dump" is the source
		-- we happen to read; "the class list" is the thing that is missing.
		dumpError = "could not load the class list: " .. tostring(body)
		return false
	end

	local decoded
	local decodeOk = pcall(function()
		decoded = HttpService:JSONDecode(body)
	end)
	if not decodeOk or type(decoded) ~= "table" or type((decoded :: any).Classes) ~= "table" then
		dumpError = "the class list was not valid JSON"
		return false
	end

	local map: { [string]: any } = {}
	for _, class in ipairs((decoded :: any).Classes) do
		map[class.Name] = class
	end
	dumpClasses = map
	return true
end
Props.preload = loadDump

-- Readable, developer-facing property names for a class, walking the superclass
-- chain (Part itself declares only 3 properties; Size/Anchored/CFrame all come
-- from BasePart).
--
-- The serialization filter is `CanSave or CanLoad`, not `CanSave` alone: Part
-- serialises through lowercase aliases, so a CanSave-only filter silently drops
-- Size, Color, Shape and Rotation, and Humanoid.Health.
function Props.names(className: string): ({ string }?, string?)
	local cached = propCache[className]
	if cached then return cached, nil end
	if not loadDump() then return nil, dumpError end

	local names: { string } = {}
	local seen: { [string]: boolean } = {}
	local class = (dumpClasses :: any)[className]
	if not class then
		return nil, "unknown class: " .. className
	end

	while class do
		for _, member in ipairs(class.Members) do
			local security = member.Security
			if type(security) == "table" then
				security = security.Read
			end
			local serialization = member.Serialization

			if member.MemberType == "Property"
				and security == "None"
				and not seen[member.Name]
				and serialization
				and (serialization.CanSave or serialization.CanLoad)
			then
				local skip = false
				-- Tags is a mixed array: plain strings plus occasional
				-- { PreferredDescriptorName = ... } objects on renamed members.
				for _, tag in ipairs(member.Tags or {}) do
					if type(tag) == "string" and SKIP_TAGS[tag] then
						skip = true
						break
					end
				end
				if not skip then
					seen[member.Name] = true
					table.insert(names, member.Name)
				end
			end
		end
		class = (dumpClasses :: any)[class.Superclass]
	end

	table.sort(names)
	propCache[className] = names
	return names, nil
end

-- A pristine instance of the same class, used as the default-value baseline.
-- Services, Terrain and other non-creatable classes throw, those fall back to
-- printing every property.
function Props.default(className: string): Instance?
	local cached = defaultCache[className]
	if cached == nil then
		local ok, inst = pcall(Instance.new, className)
		cached = (ok and inst) or false
		defaultCache[className] = cached
	end
	return cached or nil
end

-- Is this a real Roblox class name?
--
-- IsA() cannot answer this. Per the Roblox docs, "if 'className' is not a valid
-- class type in ROBLOX, this function will always return false", it does NOT
-- throw, so a pcall around it can never distinguish a typo from a legitimate
-- non-match. The dump is the only thing here that knows the class list.
--
-- Instance.new() is not an alternative either: it throws for every service and
-- for Terrain, which are perfectly valid class names to filter on.
--
-- Safe to call from inside a stream callback. main preloads the dump at startup
-- so dumpClasses is already set, and if the fetch failed dumpError is set and
-- loadDump() returns immediately, neither path yields.
function Props.classExists(className: string): boolean
	if not loadDump() then
		return true   -- no dump to check against; don't block the search
	end
	return (dumpClasses :: any)[className] ~= nil
end

-- Self-test
-- Fails loudly if the dump schema changes, the superclass walk breaks, or the
-- serialization filter starts eating real properties. Needs HTTP, so run it from
-- a background task after preload.
function Props.selfTest(): (boolean, string?)
	local names, err = Props.names("Part")
	if not names then
		return false, "Props.names failed: " .. tostring(err)
	end
	local has: { [string]: boolean } = {}
	for _, n in ipairs(names) do has[n] = true end

	-- Size/Anchored come from BasePart (superclass walk); Shape is CanLoad-only
	-- and disappears if the filter regresses to CanSave.
	for _, required in ipairs({ "Size", "Anchored", "CFrame", "Shape", "Transparency" }) do
		if not has[required] then
			return false, "Part is missing property: " .. required
		end
	end
	-- Instance.Archivable has no serialization flags; DataCost is deprecated.
	for _, excluded in ipairs({ "Archivable", "DataCost" }) do
		if has[excluded] then
			return false, "Part should not expose: " .. excluded
		end
	end

	local guiNames = Props.names("TextLabel")
	if not guiNames or #guiNames <= #names then
		return false, "TextLabel should expose more properties than Part"
	end
	return true, nil
end

return Props
