--!strict
--!optimize 2
-- NvidiaAuth.luau: NVIDIA NIM credentials, and there is no flow to speak of.
--
-- Answers the same calls AnthropicAuth and OpenRouterAuth do, because Commands
-- and the settings panel drive all three through one code path. Underneath it is
-- the simplest of the three: NVIDIA has no OAuth, so there is no PKCE, no code
-- exchange and no verifier to persist. `startLogin` hands back the page where a
-- key is minted and `completeLogin` stores what was pasted.
--
-- The key is a personal NGC key, `nvapi-` prefixed, valid across every model in
-- the catalogue. It DOES expire — six months, unless it was minted as "Never
-- Expire" — but nothing in a response says when, so `tokenExpiry` reports nil
-- rather than a guess, and a 401 is handled where every other provider handles
-- one: as a credential that has to be replaced by hand.
--
-- Reference: https://build.nvidia.com/settings/api-keys

-- The `plugin` global only exists in the root plugin Script, not in the
-- ModuleScripts it requires, so the caller hands it over via Initialize.
local plugin: any = nil

-- Not an authorize endpoint — a settings page. Commands prints it under "Open
-- this URL in your browser", which reads correctly for "generate a key here".
local API_KEYS_URL = "https://build.nvidia.com/settings/api-keys"

-- Setting keys (no dots, no backslashes: Plugin:SetSetting silently fails otherwise)
local KEY_API_KEY = "nvidia_api_key"

-- No prefix check, deliberately, and the Gemini provider is why: the same guard
-- there was written against "AIza" and refused every key Google now issues,
-- because the prefix changed on Google's schedule and the copy of it here did
-- not. A credential's format is the vendor's to change, so a check on it fails
-- CLOSED — a working key refused with a confident, wrong message — and the first
-- request validates a key anyway. NVIDIA keys happen to begin `nvapi-` today;
-- that fact belongs in the message below, not in a gate.

-- A REFERENCE POINT, not a fact about this account, and the distinction matters
-- enough to spell out. NVIDIA publishes no rate limit: 40/min is the figure its
-- staff and users quote on the developer forums, the real ceiling is only shown
-- in the build.nvidia.com UI, and an account that asked for an increase is on
-- 200. So this is what the bar below is drawn against and nothing more.
--
-- It is also GLOBAL — one budget for the key, shared across every model — not
-- per model as this file first claimed. That error mattered: it made "switch
-- model" sound like a way out of a 429 when the two models draw on the same
-- allowance. Same trap OpenRouter's 402 message already warns about.
local FREE_RPM = 40

-- What we can actually measure. There is no quota endpoint and no rate-limit
-- header on any NVIDIA response — verified against both /v1/models and
-- /v1/chat/completions, and the developer forums list the missing headers as a
-- standing complaint — so the server will not tell us how much is left.
--
-- Counting our own sends is the one honest gauge available, and for this plugin
-- it is the interesting number anyway: a single agent turn is many requests, so
-- the rate that matters is the one this plugin is generating right now.
--
-- ponytail: a plain array pruned on write, not a ring buffer. It holds at most a
-- minute of sends — tens of entries, a couple of hundred on an upgraded key.
local RPM_WINDOW = 60
local sendTimes: { number } = {}

-- Called once per ATTEMPT by the wire, retries included, because a retry spends
-- the allowance exactly like a first try does.
local function noteRequest()
	local now = os.time()
	local kept: { number } = {}
	for _, at in ipairs(sendTimes) do
		if now - at < RPM_WINDOW then kept[#kept + 1] = at end
	end
	kept[#kept + 1] = now
	sendTimes = kept
end

local function recentRequests(): number
	local now = os.time()
	local n = 0
	for _, at in ipairs(sendTimes) do
		if now - at < RPM_WINDOW then n += 1 end
	end
	return n
end

local function getSetting(key: string): any
	if not plugin then return nil end
	return plugin:GetSetting(key)
end

local function Initialize(pluginRef: any)
	plugin = pluginRef
end

-- No flow to begin, so nothing is stored and nothing expires between this call
-- and the next. `state` is in the return shape only because Commands and the
-- other auth modules share it.
local function startLogin(): { authorizeUrl: string, state: string }
	return { authorizeUrl = API_KEYS_URL, state = "" }
end

local function completeLogin(pasted: string): (boolean, string?)
	local key = pasted:match("^%s*(.-)%s*$") or ""
	if key == "" then
		return false, "No key given."
	end
	-- Whitespace in the middle is the one thing no key of any format has, and it
	-- catches the realistic mis-paste: a sentence, or a whole URL with a title
	-- attached. Everything else is the API's business.
	if key:find("%s") then
		return false, "That has spaces in it, so it is not a key. Copy just the key from "
			.. API_KEYS_URL
	end
	if not plugin then return false, "Plugin not initialized." end
	-- Stored as-is; the first request is what validates it, and pretending to
	-- check here would mean a round trip that proves nothing the next one does not.
	plugin:SetSetting(KEY_API_KEY, key)
	return true
end

local function isLoggedIn(): boolean
	local key = getSetting(KEY_API_KEY)
	return type(key) == "string" and key ~= ""
end

-- The signature matches AnthropicAuth's (token, error) so Stream's request hook
-- reads the same either way. There is nothing to refresh, so this never yields.
local function getAccessToken(): (string?, string?)
	local key = getSetting(KEY_API_KEY)
	if type(key) ~= "string" or key == "" then
		return nil, "Not logged in. Use /login."
	end
	return key, nil
end

-- Nothing to do. A personal key is not refreshable: when one stops working it has
-- been revoked or has aged out, and the fix is a new key rather than a new token.
local function refresh(): (boolean, string?)
	return false, "NVIDIA keys are not refreshable; mint a new one at " .. API_KEYS_URL
end

local function logout()
	if not plugin then return end
	plugin:SetSetting(KEY_API_KEY, "")
end

-- A key does expire, but no response carries the date, so callers render nil as
-- "unknown" — which is the honest answer rather than a number invented here.
local function tokenExpiry(): number?
	return nil
end

-- Rows for the settings panel, already formatted, same contract as every auth module.
--
-- NVIDIA publishes no credits or usage endpoint and sends no rate-limit header,
-- so unlike OpenRouter there is nothing to fetch and this never touches the
-- network. What it can report is what this plugin itself has spent, which for an
-- agent is the number that matters: a turn is many requests, and the rate is
-- generated here rather than by a person typing.
local function fetchUsage(): ({ { label: string, value: string, bar: number? } }?, string?)
	if not isLoggedIn() then
		return nil, "Not logged in."
	end
	-- The first row is measured, the second is a reference. Ordered that way on
	-- purpose: the number this plugin actually knows goes first, and the one it
	-- is only quoting is labelled as such rather than presented as a quota.
	local sent = recentRequests()
	return {
		{
			label = "Sent",
			value = string.format("%d in the last minute", sent),
			bar = math.clamp(sent / FREE_RPM, 0, 1),
		},
		{ label = "Key limit", value = string.format("~%d/min, unpublished", FREE_RPM) },
	}, nil
end

return {
	-- Exported so the wire can quote it back when a request is refused for rate,
	-- and two copies of a limit is two things to get wrong on the day it changes.
	FREE_RPM = FREE_RPM,
	noteRequest = noteRequest,
	recentRequests = recentRequests,
	API_KEYS_URL = API_KEYS_URL,
	Initialize = Initialize,
	startLogin = startLogin,
	completeLogin = completeLogin,
	isLoggedIn = isLoggedIn,
	getAccessToken = getAccessToken,
	fetchUsage = fetchUsage,
	logout = logout,
	refresh = refresh,
	tokenExpiry = tokenExpiry,
}
