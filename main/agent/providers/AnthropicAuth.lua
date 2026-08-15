--!strict
--!optimize 2
-- AnthropicAuth.luau: Anthropic subscription OAuth flow, plugin-only (no relay server)
--
-- Implements Authorization Code + PKCE flow using claude.ai/oauth/authorize
-- in "copy/paste mode" (code=true). The user opens the auth URL in their own
-- browser, authorizes, copies the resulting code back into the plugin.
--
-- References:
--   - https://gist.github.com/ben-vargas/c7c7cbfebbb47278f45feca9cef309d1
--   - https://www.linkedin.com/pulse/how-claude-code-authentication-actually-works-under-sigrid-jin-wkphc
--
-- Public API:
--   OAuth.startLogin() -> { authorizeUrl: string }   -- begin a new PKCE flow
--   OAuth.completeLogin(pastedCode: string) -> boolean, string?
--       -- exchange the user-pasted code for tokens, persist them
--   OAuth.isLoggedIn() -> boolean
--   OAuth.getAccessToken() -> string?, string?   -- token, error
--       -- refreshes automatically if within 60s of expiry
--   OAuth.logout() -> ()
--   OAuth.tokenExpiry() -> number?   -- unix seconds, or nil if not logged in
--
-- Storage: Plugin:SetSetting keys cannot contain `.` or `\` (per devforum),
-- so we use plain underscore-separated keys.

local Sha256 = require(script.Parent.Parent.Parent
	:WaitForChild("util"):WaitForChild("Sha256")) :: any

local HttpService = game:GetService("HttpService")
local warn = warn

-- The `plugin` global only exists in the root plugin Script, NOT in ModuleScripts
-- required by it. The Plugin docs explicitly show this pattern:
--   https://create.roblox.com/docs/reference/engine/classes/Plugin
--   "Script - Pass the Plugin Global to a ModuleScript"
-- We require the caller to call OAuth:Initialize(plugin) before using any
-- function that touches settings storage.
local plugin: any = nil

-- Constants (verified against the gist and the LinkedIn writeup)
local CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
local TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
local REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback"
local SCOPES = "org:create_api_key user:profile user:inference"
-- Subscription usage, the same endpoint Claude Code's /usage reads for its plan
-- bars. Not in the public API reference (that documents the API-key rate limit
-- headers, which OAuth traffic doesn't get). Confirmed live: this host answers
-- with authentication_error on a bad bearer, so the route is real;
-- claude.ai/api/oauth/usage is fronted by a bot check and 403s.
local USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

-- Setting keys (no dots, no backslashes. Plugin:SetSetting silently fails otherwise)
local KEY_ACCESS_TOKEN = "claude_access_token"
local KEY_REFRESH_TOKEN = "claude_refresh_token"
local KEY_EXPIRES_AT = "claude_expires_at"
local KEY_PKCE_VERIFIER = "claude_pkce_verifier"  -- ephemeral, only during login
local KEY_PKCE_STATE    = "claude_pkce_state"     -- ephemeral, only during login

-- PKCE primitives
-- Generate a high-entropy code_verifier (43-128 chars, base64url of random bytes).
-- Roblox has no crypto RNG; HttpService:GenerateGUID(false) returns a 32-hex-char
-- GUID without braces. We concatenate two GUIDs (64 hex chars = 256 bits entropy)
-- then hex-decode to 32 bytes and base64url-encode. This matches the spec's
-- recommendation of 256 random bits.
local function generateVerifier(): string
	local guid1 = HttpService:GenerateGUID(false)
	local guid2 = HttpService:GenerateGUID(false)
	local hex = (guid1 .. guid2):gsub("-", "")  -- 64 hex chars, no dashes
	-- Hex-decode to 32 raw bytes, then base64url-encode
	local bytes = {}
	for i = 1, #hex, 2 do
		local byte = tonumber(string.sub(hex, i, i + 1), 16) :: number
		table.insert(bytes, string.char(byte))
	end
	local raw = table.concat(bytes)
	-- base64url (no padding), reuse Sha256's helper logic
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	local out = {}
	local i = 1
	while i <= #raw do
		local b1 = string.byte(raw, i) :: number
		local b2 = string.byte(raw, i + 1) or 0
		local b3 = string.byte(raw, i + 2) or 0
		local n = b1 * 65536 + b2 * 256 + b3
		table.insert(out, string.sub(chars, math.floor(n / 262144) + 1, math.floor(n / 262144) + 1))
		table.insert(out, string.sub(chars, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
		table.insert(out, string.sub(chars, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
		if i + 2 <= #raw then
			table.insert(out, string.sub(chars, n % 64 + 1, n % 64 + 1))
		end
		i = i + 3
	end
	return table.concat(out)
end

-- Compute code_challenge = base64url( sha256( verifier ) )
-- We already have Sha256.hash() returning 32 raw bytes and base64url() taking a string
-- to hash then base64. We need a variant that base64urls *raw bytes*. Reimplement inline.
local function base64urlOfBytes(raw: string): string
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	local out = {}
	local i = 1
	while i <= #raw do
		local b1 = string.byte(raw, i) :: number
		local b2 = string.byte(raw, i + 1) or 0
		local b3 = string.byte(raw, i + 2) or 0
		local n = b1 * 65536 + b2 * 256 + b3
		table.insert(out, string.sub(chars, math.floor(n / 262144) + 1, math.floor(n / 262144) + 1))
		table.insert(out, string.sub(chars, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
		table.insert(out, string.sub(chars, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
		if i + 2 <= #raw then
			table.insert(out, string.sub(chars, n % 64 + 1, n % 64 + 1))
		end
		i = i + 3
	end
	return table.concat(out)
end

local function computeChallenge(verifier: string): string
	local rawHash = Sha256.hash(verifier)
	return base64urlOfBytes(rawHash)
end

-- Random state string for CSRF protection (any opaque token works)
local function generateState(): string
	return HttpService:GenerateGUID(false):gsub("-", "")
end

-- HTTP helper
-- HttpService:RequestAsync is synchronous and blocks the calling thread.
-- Always call from a coroutine/task.spawn. Returns the response dictionary
-- or throws on transport error.
local function httpPostJson(url: string, bodyTable: { [string]: any }): { [string]: any }
	local bodyStr = HttpService:JSONEncode(bodyTable)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = {
				["content-type"] = "application/json",
				["accept"] = "application/json",
			},
			Body = bodyStr,
		})
	end)
	if not ok then
		return {
			Success = false,
			StatusCode = 0,
			Body = "",
			StatusMessage = tostring(response),
		}
	end
	return response :: any
end

-- Storage helpers
-- All storage helpers guard against `plugin` being nil (i.e. Initialize not called yet).
-- They fail soft rather than crashing: a nil plugin means we treat state as empty
-- and refuse to write.

local function saveTokens(accessToken: string, refreshToken: string, expiresIn: number)
	if not plugin then return end
	plugin:SetSetting(KEY_ACCESS_TOKEN, accessToken)
	plugin:SetSetting(KEY_REFRESH_TOKEN, refreshToken)
	plugin:SetSetting(KEY_EXPIRES_AT, os.time() + expiresIn)
end

local function clearTokens()
	if not plugin then return end
	plugin:SetSetting(KEY_ACCESS_TOKEN, "")
	plugin:SetSetting(KEY_REFRESH_TOKEN, "")
	plugin:SetSetting(KEY_EXPIRES_AT, 0)
end

local function clearPkceState()
	if not plugin then return end
	plugin:SetSetting(KEY_PKCE_VERIFIER, "")
	plugin:SetSetting(KEY_PKCE_STATE, "")
end

local function getSetting(key: string): any
	if not plugin then return nil end
	return plugin:GetSetting(key)
end

-- Public API

-- MUST be called once from the root plugin script before any storage-touching API.
--   OAuth:Initialize(plugin)
-- Idempotent: safe to call multiple times.
local function Initialize(pluginRef: any)
	plugin = pluginRef
end

-- Begin a new login flow: generate PKCE, persist verifier+state, return authorize URL.
local function startLogin(): { authorizeUrl: string, state: string }
	if not plugin then
		return { authorizeUrl = "", state = "" }
	end

	local verifier = generateVerifier()
	local challenge = computeChallenge(verifier)
	local state = generateState()

	plugin:SetSetting(KEY_PKCE_VERIFIER, verifier)
	plugin:SetSetting(KEY_PKCE_STATE, state)

	-- Build URL with proper URL-encoding of each parameter.
	-- `code=true` enables copy/paste mode. Anthropic's redirect page will display
	-- the auth code prominently instead of trying to hit a localhost callback.
	local params = {
		{ "code",                  "true" },
		{ "client_id",             CLIENT_ID },
		{ "response_type",         "code" },
		{ "redirect_uri",          REDIRECT_URI },
		{ "scope",                 SCOPES },
		{ "code_challenge",        challenge },
		{ "code_challenge_method", "S256" },
		{ "state",                 state },
	}
	local qs = {}
	for _, kv in ipairs(params) do
		table.insert(qs, kv[1] .. "=" .. HttpService:UrlEncode(kv[2]))
	end
	local url = AUTHORIZE_URL .. "?" .. table.concat(qs, "&")

	return { authorizeUrl = url, state = state }
end

-- Exchange the user-pasted code for tokens. Returns (true, nil) on success,
-- (false, errorMessage) on failure.
local function completeLogin(pastedCode: string): (boolean, string?)
	if pastedCode == nil or pastedCode == "" then
		return false, "No code provided."
	end

	-- The user might paste "CODE#STATE" or just "CODE". Split on '#'.
	local code, returnedState = string.match(pastedCode, "^([^#]+)#?(.*)$")
	if not code or code == "" then
		code = pastedCode
		returnedState = ""
	end

	local verifier = getSetting(KEY_PKCE_VERIFIER) :: string?
	local expectedState = getSetting(KEY_PKCE_STATE) :: string?

	if not verifier or verifier == "" then
		return false, "No PKCE verifier found. Click 'Start Login' first."
	end

	-- If we have an expected state and a returned state, verify they match (CSRF check).
	if expectedState and expectedState ~= "" and returnedState and returnedState ~= "" then
		if returnedState ~= expectedState then
			return false, "State mismatch — possible CSRF attack. Aborting."
		end
	end

	local body = {
		grant_type = "authorization_code",
		code = code,
		redirect_uri = REDIRECT_URI,
		client_id = CLIENT_ID,
		code_verifier = verifier,
		state = expectedState or verifier,
	}

	local response = httpPostJson(TOKEN_URL, body)
	if not response.Success then
		return false, string.format(
			"Token exchange failed (HTTP %s): %s",
			tostring(response.StatusCode),
			tostring(response.Body)
		)
	end

	local parsed
	local ok, err = pcall(function()
		parsed = HttpService:JSONDecode(response.Body :: string)
	end)
	if not ok or type(parsed) ~= "table" then
		return false, "Token response was not valid JSON: " .. tostring(err)
	end

	local accessToken = (parsed :: any).access_token
	local refreshToken = (parsed :: any).refresh_token
	local expiresIn = (parsed :: any).expires_in or 3600

	if type(accessToken) ~= "string" or accessToken == "" then
		return false, "Token response missing access_token. Body: " .. tostring(response.Body)
	end
	if type(refreshToken) ~= "string" or refreshToken == "" then
		return false, "Token response missing refresh_token. Body: " .. tostring(response.Body)
	end

	saveTokens(accessToken, refreshToken, tonumber(expiresIn) :: number)
	clearPkceState()
	return true, nil
end

-- Refresh tokens using the stored refresh_token. Returns (true, nil) on success.
local function refresh(): (boolean, string?)
	local refreshToken = getSetting(KEY_REFRESH_TOKEN) :: string?
	if not refreshToken or refreshToken == "" then
		return false, "No refresh_token stored — please log in again."
	end

	local body = {
		grant_type = "refresh_token",
		refresh_token = refreshToken,
		client_id = CLIENT_ID,
	}

	local response = httpPostJson(TOKEN_URL, body)
	if not response.Success then
		-- Only clear tokens on 4xx (revoked/expired refresh token).
		-- On transport errors (status 0) or 5xx, keep tokens so the user can retry.
		local code = tonumber(response.StatusCode) or 0
		warn(string.format("[Claude Code] refresh failed: HTTP %s, body: %s",
			tostring(response.StatusCode), tostring(response.Body)))
		if code >= 400 and code < 500 then
			clearTokens()
		end
		return false, string.format(
			"Refresh failed (HTTP %s): %s",
			tostring(response.StatusCode),
			tostring(response.Body)
		)
	end

	local parsed
	local ok, err = pcall(function()
		parsed = HttpService:JSONDecode(response.Body :: string)
	end)
	if not ok or type(parsed) ~= "table" then
		warn("[Claude Code] refresh: response was not valid JSON: " .. tostring(err))
		return false, "Refresh response was not valid JSON: " .. tostring(err)
	end

	local accessToken = (parsed :: any).access_token
	local newRefresh = (parsed :: any).refresh_token or refreshToken  -- some servers rotate, some don't
	local expiresIn = (parsed :: any).expires_in or 3600

	if type(accessToken) ~= "string" or accessToken == "" then
		warn("[Claude Code] refresh: response missing access_token. Body: " .. tostring(response.Body))
		return false, "Refresh response missing access_token."
	end

	-- Nothing is logged on the way through here, deliberately. Output is a shared
	-- window that ends up in screenshots and bug reports, and a token prefix is
	-- still token material. Failures below carry their reason back to the caller,
	-- which is where a person can actually see it.
	saveTokens(accessToken, newRefresh, tonumber(expiresIn) :: number)
	return true, nil
end

-- Returns true if we have a non-empty refresh token (i.e., the user has logged in
-- at least once and not logged out).
local function isLoggedIn(): boolean
	local rt = getSetting(KEY_REFRESH_TOKEN) :: string?
	return rt ~= nil and rt ~= ""
end

-- Returns the current access token, refreshing if it's within 60 seconds of expiry.
-- Returns (token, nil) on success or (nil, errorMessage) on failure.
local function getAccessToken(): (string?, string?)
	local at = getSetting(KEY_ACCESS_TOKEN) :: string?
	local rt = getSetting(KEY_REFRESH_TOKEN) :: string?
	local exp = getSetting(KEY_EXPIRES_AT) :: number?

	if not rt or rt == "" then
		return nil, "Not logged in."
	end
	if not at or at == "" then
		-- Access token missing but refresh token present, try refresh.
		warn("[Claude Code] getAccessToken: at missing, refreshing…")
		local ok, err = refresh()
		if not ok then
			return nil, err or "Refresh failed."
		end
		at = getSetting(KEY_ACCESS_TOKEN) :: string?
		return at, nil
	end

	-- Refresh if expired or within 60s of expiry (clock skew safety margin).
	if exp and (os.time() + 60 >= exp) then
		warn("[Claude Code] getAccessToken: token expired/near-expiry, refreshing…")
		local ok, err = refresh()
		if not ok then
			return nil, err or "Refresh failed."
		end
		at = getSetting(KEY_ACCESS_TOKEN) :: string?
		return at, nil
	end

	--warn("[Claude Code] getAccessToken: returning cached token (still valid)")
	return at, nil
end

-- Current plan usage: one entry per limit window, each carrying a utilization
-- and the time it resets. Claude Code reads five_hour and seven_day out of this
-- for its two bars (a seven_day_overage_included window rides along when the
-- account has usage credits). Blocking, like every other call here, run it from
-- a task.spawn. Returns (windows, nil) or (nil, errorMessage).
local function fetchUsage(): ({ [string]: any }?, string?)
	local token, tokenErr = getAccessToken()
	if not token then
		return nil, tokenErr or "Not logged in."
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = USAGE_URL,
			Method = "GET",
			Headers = {
				["Authorization"] = "Bearer " .. token,
				["accept"] = "application/json",
				-- Same identifier the message stream sends. The OAuth routes gate
				-- on it, so a request without it can come back 403 even with a
				-- valid token.
				["x-app"] = "cli",
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
	return parsed :: any, nil
end

local function logout()
	clearTokens()
	clearPkceState()
end

local function tokenExpiry(): number?
	local exp = getSetting(KEY_EXPIRES_AT) :: number?
	if not exp or exp == 0 then return nil end
	return exp
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
	-- Exposed for tests / debugging
	_generateVerifier = generateVerifier,
	_computeChallenge = computeChallenge,
	_CLIENT_ID = CLIENT_ID,
	_TOKEN_URL = TOKEN_URL,
	_AUTHORIZE_URL = AUTHORIZE_URL,
	_REDIRECT_URI = REDIRECT_URI,
	_SCOPES = SCOPES,
}
