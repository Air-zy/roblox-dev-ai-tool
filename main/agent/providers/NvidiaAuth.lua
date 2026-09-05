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

local HttpService = game:GetService("HttpService")

-- The `plugin` global only exists in the root plugin Script, not in the
-- ModuleScripts it requires, so the caller hands it over via Initialize.
local plugin: any = nil

-- Not an authorize endpoint — a settings page. Commands prints it under "Open
-- this URL in your browser", which reads correctly for "generate a key here".
local API_KEYS_URL = "https://build.nvidia.com/settings/api-keys"

-- Setting keys (no dots, no backslashes: Plugin:SetSetting silently fails otherwise)
local KEY_API_KEY = "nvidia_api_key"

-- Every personal key carries this. Checked on paste rather than on the first
-- request, because the whole flow IS a paste: the likely failure is the wrong
-- clipboard entry, and the middle of a turn is a poor place to find that out.
local KEY_PREFIX = "nvapi-"

-- Documented as a best-effort ceiling rather than an SLA, and per model rather
-- than per account. Worth stating in the panel because an agent turn is many
-- requests, not one, so it arrives sooner here than it would in a chat window.
local FREE_RPM = 40

local function getSetting(key: string): any
	if not plugin then return nil end
	return plugin:GetSetting(key)
end

local function Initialize(pluginRef: any)
	plugin = pluginRef
end

-- No flow to begin, so nothing is stored and nothing expires between this call
-- and the next. `state` is in the return shape only because Commands and the
-- other two auth modules share it.
local function startLogin(): { authorizeUrl: string, state: string }
	return { authorizeUrl = API_KEYS_URL, state = "" }
end

local function completeLogin(pasted: string): (boolean, string?)
	local key = pasted:match("^%s*(.-)%s*$") or ""
	if key == "" then
		return false, "No key given."
	end
	if key:sub(1, #KEY_PREFIX) ~= KEY_PREFIX then
		return false, "That does not look like an NVIDIA key — they begin `nvapi-`. "
			.. "Generate one at " .. API_KEYS_URL
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

-- Rows for the settings panel, already formatted, same contract as the other two.
--
-- NVIDIA publishes no credits or usage endpoint, so unlike OpenRouter there is
-- nothing to fetch and this never touches the network. One row rather than an
-- error: the rate limit is the thing that actually ends a session here, and it is
-- worth stating even though knowing it costs no request. Same reasoning as the
-- "Free models — N req/day" row OpenRouterAuth prints beside its real bars.
local function fetchUsage(): ({ { label: string, value: string, bar: number? } }?, string?)
	if not isLoggedIn() then
		return nil, "Not logged in."
	end
	return {
		{ label = "Rate limit", value = string.format("~%d req/min per model", FREE_RPM) },
		{ label = "Credits", value = "no usage endpoint" },
	}, nil
end

return {
	-- Exported so the wire can quote it back when a request is refused for rate,
	-- and two copies of a limit is two things to get wrong on the day it changes.
	FREE_RPM = FREE_RPM,
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
