--!strict
--!optimize 2
-- OpenRouterAuth.luau: OpenRouter login, plugin-only (no relay server).
--
-- Same shape as AnthropicAuth and deliberately so — /login prints a URL, the
-- user authorises in a browser, /code pastes the result back — but the flow
-- underneath is simpler in three ways worth knowing:
--
--   * No client_id. OpenRouter's PKCE flow does not have one, so there is
--     nothing to register and nothing to keep in step with an upstream.
--   * Headless by design. Omitting callback_url is a documented mode: the user
--     is shown the code on screen to copy, which is the only thing a Studio
--     plugin could do with it anyway. key_label is required in that mode and
--     becomes the name of the key on their dashboard.
--   * What comes back is an API KEY, not an access/refresh pair. It does not
--     expire, so `refresh` has nothing to do and `tokenExpiry` has nothing to
--     report. Stream.luau's refresh hook is simply not wired up for this
--     provider; a 401 here means the key was deleted, and retrying with the
--     same one cannot help.
--
-- Because the credential IS a plain API key, /code also accepts one pasted
-- directly. Anyone who already has a key from the dashboard can skip the
-- browser round trip entirely.
--
-- Reference: https://openrouter.ai/docs/use-cases/oauth-pkce

local Pkce = require(script.Parent:WaitForChild("Pkce"))

local HttpService = game:GetService("HttpService")
local warn = warn

-- The `plugin` global only exists in the root plugin Script, not in the
-- ModuleScripts it requires, so the caller hands it over via Initialize.
local plugin: any = nil

local AUTHORIZE_URL = "https://openrouter.ai/auth"
local KEYS_URL = "https://openrouter.ai/api/v1/auth/keys"
-- Credits, spend and whether this account is still on the free tier. The
-- free-model request caps key off that last flag, which is why it is read.
local KEY_URL = "https://openrouter.ai/api/v1/key"
-- What the key is called on the user's dashboard. Required when callback_url is
-- omitted, which is the headless mode this uses.
local KEY_LABEL = "Claude Code for Roblox"

-- Setting keys (no dots, no backslashes: Plugin:SetSetting silently fails otherwise)
local KEY_API_KEY = "openrouter_api_key"
local KEY_PKCE_VERIFIER = "openrouter_pkce_verifier"  -- ephemeral, only during login

-- Free-model request caps, which are the limit a free user actually runs into
-- long before credits matter. Both numbers are platform-level and apply to any
-- model whose id ends `:free`; the higher one unlocks at $10 of lifetime
-- purchases and stays unlocked even at a zero balance.
local FREE_RPD = 50
local PAID_RPD = 1000

local function getSetting(key: string): any
	if not plugin then return nil end
	return plugin:GetSetting(key)
end

local function Initialize(pluginRef: any)
	plugin = pluginRef
end

-- Begins a PKCE flow and returns the URL to open. The verifier is persisted
-- because the exchange happens in a later call, after the user has been to a
-- browser and come back — possibly after a Studio restart.
local function startLogin(): { authorizeUrl: string, state: string }
	local verifier = Pkce.verifier()
	local challenge = Pkce.challenge(verifier)
	if plugin then
		plugin:SetSetting(KEY_PKCE_VERIFIER, verifier)
	end
	local url = string.format(
		"%s?callback_url=&code_challenge=%s&code_challenge_method=S256&key_label=%s",
		AUTHORIZE_URL,
		HttpService:UrlEncode(challenge),
		HttpService:UrlEncode(KEY_LABEL))
	-- `state` is in the return shape only because Commands and AnthropicAuth
	-- share it. There is no state parameter in this flow: with no callback_url
	-- there is no redirect for anyone to forge.
	return { authorizeUrl = url, state = "" }
end

-- Exchanges a pasted authorization code for an API key — or accepts a key
-- pasted directly, since that is what this flow produces and plenty of people
-- already have one.
local function completeLogin(pasted: string): (boolean, string?)
	local code = pasted:match("^%s*(.-)%s*$") or ""
	if code == "" then
		return false, "No code given."
	end

	-- A key, not a code. Stored as-is; the first request is what validates it,
	-- and pretending to check here would mean a round trip that proves nothing
	-- the next one does not.
	if code:match("^sk%-or%-") then
		if not plugin then return false, "Plugin not initialized." end
		plugin:SetSetting(KEY_API_KEY, code)
		plugin:SetSetting(KEY_PKCE_VERIFIER, "")
		return true
	end

	local verifier = getSetting(KEY_PKCE_VERIFIER)
	if type(verifier) ~= "string" or verifier == "" then
		return false, "No login in progress. Run /login first."
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = KEYS_URL,
			Method = "POST",
			Headers = {
				["content-type"] = "application/json",
				["accept"] = "application/json",
			},
			Body = HttpService:JSONEncode({
				code = code,
				code_verifier = verifier,
				code_challenge_method = "S256",
			}),
		})
	end)
	if not ok then
		return false, "Key exchange failed: " .. tostring(response)
	end

	local res = response :: any
	if res.StatusCode ~= 200 then
		-- Codes expire ten minutes after they are issued, which is the single
		-- most likely reason to be here, so it is named rather than left to a
		-- bare status.
		return false, string.format("Key exchange: HTTP %d %s — a code expires 10 minutes after it is issued",
			res.StatusCode, tostring(res.StatusMessage))
	end

	local parsed
	local parseOk = pcall(function()
		parsed = HttpService:JSONDecode(res.Body)
	end)
	if not parseOk or type(parsed) ~= "table" then
		return false, "Key exchange: response was not JSON"
	end
	local key = (parsed :: any).key
	if type(key) ~= "string" or key == "" then
		return false, "Key exchange: no key in the response"
	end

	if not plugin then return false, "Plugin not initialized." end
	plugin:SetSetting(KEY_API_KEY, key)
	plugin:SetSetting(KEY_PKCE_VERIFIER, "")
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

-- Nothing to do: an OpenRouter key does not expire. Kept so the module answers
-- the same calls AnthropicAuth does, and returns false so any caller that reads
-- the result treats it as "no new credential", which is the truth.
local function refresh(): (boolean, string?)
	return false, "OpenRouter keys do not expire; there is nothing to refresh."
end

local function logout()
	if not plugin then return end
	plugin:SetSetting(KEY_API_KEY, "")
	plugin:SetSetting(KEY_PKCE_VERIFIER, "")
end

-- No expiry to report. Callers render nil as "unknown", which is the honest
-- answer for a credential with no lifetime.
local function tokenExpiry(): number?
	return nil
end

local function money(credits: any): string
	if type(credits) ~= "number" then return "—" end
	return string.format("$%.2f", credits)
end

-- Rows for the settings panel, already formatted. The caller does not know what
-- an OpenRouter key response looks like and should not have to: Anthropic
-- reports two rolling utilisation windows and this reports credits, and the one
-- thing they have in common is that they end up as rows.
local function fetchUsage(): ({ { label: string, value: string, bar: number? } }?, string?)
	local key, keyErr = getAccessToken()
	if not key then
		return nil, keyErr or "Not logged in."
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = KEY_URL,
			Method = "GET",
			Headers = {
				["Authorization"] = "Bearer " .. key,
				["accept"] = "application/json",
			},
		})
	end)
	if not ok then
		return nil, "usage request failed: " .. tostring(response)
	end

	local res = response :: any
	if res.StatusCode ~= 200 then
		return nil, string.format("usage: HTTP %d %s", res.StatusCode, tostring(res.StatusMessage))
	end

	local parsed
	local parseOk = pcall(function()
		parsed = HttpService:JSONDecode(res.Body)
	end)
	if not parseOk or type(parsed) ~= "table" then
		return nil, "usage: response was not JSON"
	end
	-- The endpoint wraps its payload in `data`; older responses did not, so both
	-- are accepted rather than betting on one.
	local d = ((parsed :: any).data or parsed) :: any

	local rows: { { label: string, value: string, bar: number? } } = {}

	-- A key with no limit is the normal case for a pay-as-you-go account, and
	-- there is no fraction to draw for it — only a number spent.
	if type(d.limit) == "number" and d.limit > 0 then
		table.insert(rows, {
			label = "Credits",
			value = string.format("%s of %s", money(d.usage), money(d.limit)),
			bar = math.clamp((d.usage or 0) / d.limit, 0, 1),
		})
	else
		table.insert(rows, { label = "Credits", value = money(d.usage) .. " used" })
	end

	if type(d.usage_daily) == "number" then
		table.insert(rows, { label = "Today", value = money(d.usage_daily) })
	end

	-- The cap free models actually hit. Requests, not credits, and it is the
	-- number that ends a session early — so it is worth a row of its own even
	-- though it costs nothing.
	table.insert(rows, {
		label = "Free models",
		value = string.format("%d req/day", if d.is_free_tier == false then PAID_RPD else FREE_RPD),
	})

	return rows, nil
end

return {
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
