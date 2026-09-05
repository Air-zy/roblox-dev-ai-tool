--!strict
--!optimize 2
-- GeminiAuth.luau: Google AI Studio credentials. A pasted key, like NVIDIA's.
--
-- Answers the same calls the other three auth modules do, because Commands and
-- the settings panel drive all of them through one code path. There is no OAuth
-- here: AI Studio issues a project-scoped API key and that is the whole
-- credential, so `startLogin` hands back the page that mints one and
-- `completeLogin` stores what was pasted.
--
-- The key does not expire on a schedule and cannot be renewed in place, so
-- `refresh` has nothing to do and `tokenExpiry` has nothing to report. What it
-- CAN do is stop working without being deleted: a key is bound to a Google Cloud
-- project and can be restricted to particular APIs, so one that is valid
-- everywhere else is refused here if the Generative Language API is not among
-- them. That is why the wire's `explain` says so rather than leaving a bare 400.
--
-- Reference: https://aistudio.google.com/apikey

-- The `plugin` global only exists in the root plugin Script, not in the
-- ModuleScripts it requires, so the caller hands it over via Initialize.
local plugin: any = nil

-- A settings page rather than an authorize endpoint. Commands prints it under
-- "Open this URL in your browser", which reads correctly for "make a key here".
local API_KEYS_URL = "https://aistudio.google.com/apikey"
-- Where the live per-minute and per-day numbers are. There is no API for them,
-- so the panel points at the page instead of inventing a bar.
local RATE_LIMIT_URL = "https://aistudio.google.com/rate-limit"

-- Setting key (no dots, no backslashes: Plugin:SetSetting silently fails otherwise)
local KEY_API_KEY = "gemini_api_key"

-- No prefix check. There WAS one, for "AIza", and it rejected every key AI
-- Studio currently issues.
--
-- Google is part way through replacing Standard keys (`AIza…`, tied to a project
-- for billing) with auth keys (`AQ.…`, bound to a service account). New keys
-- have been auth keys for a while, and Google's own timeline says the API stops
-- accepting Standard keys in September 2026 — so the format this checked for is
-- the one on its way OUT, and the format it refused is the only one a person can
-- get today.
--
-- The lesson is not "list both prefixes". A credential's format belongs to the
-- vendor and changes on their schedule, so validating it here can only ever be a
-- copy of a fact that lives somewhere else, going stale silently and failing
-- CLOSED — a working key refused with a confident, wrong message. The first
-- request is what validates a key; that is what the wire's `explain` hook is
-- for. All that is checked below is what cannot be a key in any format.

local function getSetting(key: string): any
	if not plugin then return nil end
	return plugin:GetSetting(key)
end

local function Initialize(pluginRef: any)
	plugin = pluginRef
end

-- Nothing is begun and nothing is stored: there is no flow to be half way
-- through. `state` is in the return shape only because the other three auth
-- modules share it.
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

-- Nothing to do. An AI Studio key is not refreshable: when one stops working it
-- has been deleted or restricted, and the fix is a new key rather than a new
-- token.
local function refresh(): (boolean, string?)
	return false, "Google API keys are not refreshable; mint a new one at " .. API_KEYS_URL
end

local function logout()
	if not plugin then return end
	plugin:SetSetting(KEY_API_KEY, "")
end

-- No expiry to report. Callers render nil as "unknown", which is the honest
-- answer for a credential with no published lifetime.
local function tokenExpiry(): number?
	return nil
end

-- Rows for the settings panel, already formatted, same contract as the other
-- three. Google publishes no credits or quota endpoint for an AI Studio key —
-- the live numbers are only on the rate-limit page — so this never touches the
-- network and says where to look rather than drawing a bar it cannot fill.
local function fetchUsage(): ({ { label: string, value: string, bar: number? } }?, string?)
	if not isLoggedIn() then
		return nil, "Not logged in."
	end
	return {
		{ label = "Rate limit", value = "per minute and per day, by model" },
		{ label = "Live numbers", value = RATE_LIMIT_URL },
	}, nil
end

return {
	-- Exported because the wire names this URL when a key is refused, and two
	-- copies of an address is two things to get wrong on the day Google moves it.
	API_KEYS_URL = API_KEYS_URL,
	RATE_LIMIT_URL = RATE_LIMIT_URL,
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
