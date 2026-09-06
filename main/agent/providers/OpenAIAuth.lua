--!strict
--!optimize 2
-- OpenAIAuth.luau: ChatGPT/Codex subscription OAuth only.
--
-- There is deliberately no API-key login or fallback in this module. A platform
-- API key uses separately billed API tokens; this provider instead follows the
-- open-source Codex device flow and sends the resulting ChatGPT bearer token to
-- the account-backed Codex endpoint.
--
-- Codex references:
--   codex-rs/login/src/device_code_auth.rs
--   codex-rs/login/src/auth/manager.rs
--   codex-rs/model-provider/src/bearer_auth_provider.rs

local HttpService = game:GetService("HttpService")
local EncodingService = game:GetService("EncodingService")

local plugin: any = nil

local ISSUER = "https://auth.openai.com"
local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local DEVICE_USER_CODE_URL = ISSUER .. "/api/accounts/deviceauth/usercode"
local DEVICE_TOKEN_URL = ISSUER .. "/api/accounts/deviceauth/token"
local DEVICE_VERIFY_URL = ISSUER .. "/codex/device"
local DEVICE_REDIRECT_URI = ISSUER .. "/deviceauth/callback"
local TOKEN_URL = ISSUER .. "/oauth/token"

local KEY_ACCESS_TOKEN = "openai_chatgpt_access_token"
local KEY_REFRESH_TOKEN = "openai_chatgpt_refresh_token"
local KEY_ACCOUNT_ID = "openai_chatgpt_account_id"
local KEY_PLAN_TYPE = "openai_chatgpt_plan_type"
local KEY_FEDRAMP = "openai_chatgpt_fedramp"
local KEY_EXPIRES_AT = "openai_chatgpt_expires_at"
local KEY_DEVICE_AUTH_ID = "openai_device_auth_id"
local KEY_DEVICE_USER_CODE = "openai_device_user_code"
local KEY_DEVICE_INTERVAL = "openai_device_interval"
local KEY_DEVICE_STARTED_AT = "openai_device_started_at"
local KEY_RATE_LIMITS = "openai_codex_rate_limits"
-- Removed provider builds used this key. Clear it on load and logout so an API
-- credential cannot be selected accidentally by stale local state.
local KEY_LEGACY_API_KEY = "openai_api_key"

local DEVICE_TIMEOUT_SECONDS = 15 * 60
local REFRESH_WINDOW_SECONDS = 5 * 60

export type UsageRow = {
	label: string,
	value: string,
	bar: number?,
	barValue: string?,
}

local function getSetting(key: string): any
	if not plugin then return nil end
	return plugin:GetSetting(key)
end

local function setSetting(key: string, value: any)
	if plugin then plugin:SetSetting(key, value) end
end

local function clearDevice()
	setSetting(KEY_DEVICE_AUTH_ID, "")
	setSetting(KEY_DEVICE_USER_CODE, "")
	setSetting(KEY_DEVICE_INTERVAL, 0)
	setSetting(KEY_DEVICE_STARTED_AT, 0)
end

local function clearTokens()
	setSetting(KEY_ACCESS_TOKEN, "")
	setSetting(KEY_REFRESH_TOKEN, "")
	setSetting(KEY_ACCOUNT_ID, "")
	setSetting(KEY_PLAN_TYPE, "")
	setSetting(KEY_FEDRAMP, false)
	setSetting(KEY_EXPIRES_AT, 0)
	setSetting(KEY_RATE_LIMITS, "")
	setSetting(KEY_LEGACY_API_KEY, "")
	clearDevice()
end

local function request(options: { [string]: any }): ({ [string]: any }?, string?)
	local ok, response = pcall(function()
		return HttpService:RequestAsync(options)
	end)
	if not ok then return nil, tostring(response) end
	return response :: any, nil
end

local function jsonBody(response: { [string]: any }): any?
	local parsed
	if not pcall(function() parsed = HttpService:JSONDecode(tostring(response.Body or "")) end) then
		return nil
	end
	return parsed
end

local function responseError(label: string, response: { [string]: any }): string
	local parsed = jsonBody(response)
	local detail: any = type(parsed) == "table" and (parsed :: any).error or nil
	local message = if type(detail) == "table" then detail.message or detail.code
		elseif type(detail) == "string" then detail
		elseif type(parsed) == "table" then (parsed :: any).error_description
		else nil
	return string.format("%s: HTTP %s %s", label, tostring(response.StatusCode),
		tostring(message or response.StatusMessage or "request failed"))
end

local function postJson(url: string, body: { [string]: any }): ({ [string]: any }?, string?)
	return request({
		Url = url,
		Method = "POST",
		Headers = {
			["content-type"] = "application/json",
			["accept"] = "application/json",
		},
		Body = HttpService:JSONEncode(body),
	})
end

local function formBody(fields: { { string } }): string
	local parts: { string } = {}
	for _, field in ipairs(fields) do
		parts[#parts + 1] = HttpService:UrlEncode(field[1]) .. "=" .. HttpService:UrlEncode(field[2])
	end
	return table.concat(parts, "&")
end

local function postForm(url: string, fields: { { string } }): ({ [string]: any }?, string?)
	return request({
		Url = url,
		Method = "POST",
		Headers = {
			["content-type"] = "application/x-www-form-urlencoded",
			["accept"] = "application/json",
		},
		Body = formBody(fields),
	})
end

local function jwtClaims(token: string): any?
	local payload = token:match("^[^.]+%.([^.]+)%.[^.]+$")
	if not payload then return nil end
	payload = payload:gsub("%-", "+"):gsub("_", "/")
	local remainder = #payload % 4
	if remainder ~= 0 then payload ..= string.rep("=", 4 - remainder) end
	local decoded
	local ok = pcall(function()
		decoded = buffer.tostring(EncodingService:Base64Decode(buffer.fromstring(payload :: string)))
	end)
	if not ok or type(decoded) ~= "string" then return nil end
	local claims
	if not pcall(function() claims = HttpService:JSONDecode(decoded :: string) end) then return nil end
	return if type(claims) == "table" then claims else nil
end

local function tokenIdentity(idToken: string): (string?, string?, boolean)
	local claims = jwtClaims(idToken)
	local auth = type(claims) == "table" and claims["https://api.openai.com/auth"] or nil
	if type(auth) ~= "table" then return nil, nil, false end
	local accountId = type(auth.chatgpt_account_id) == "string" and auth.chatgpt_account_id or nil
	local plan = type(auth.chatgpt_plan_type) == "string" and auth.chatgpt_plan_type or nil
	return accountId, plan, auth.chatgpt_account_is_fedramp == true
end

local function jwtExpiry(token: string?): number?
	if type(token) ~= "string" or token == "" then return nil end
	local claims = jwtClaims(token)
	return if type(claims) == "table" then tonumber(claims.exp) else nil
end

local function saveTokens(accessToken: string, refreshToken: string, idToken: string?,
	requireSameAccount: boolean): (boolean, string?)
	local accountId = getSetting(KEY_ACCOUNT_ID)
	local plan = getSetting(KEY_PLAN_TYPE)
	local fedramp = getSetting(KEY_FEDRAMP) == true
	if type(idToken) == "string" and idToken ~= "" then
		local nextAccount, nextPlan, nextFedramp = tokenIdentity(idToken)
		if not nextAccount then return false, "The ChatGPT token did not include an account ID." end
		if requireSameAccount and type(accountId) == "string"
			and accountId ~= "" and accountId ~= nextAccount then
			return false, "The refreshed token belongs to a different ChatGPT account. Sign in again."
		end
		accountId, plan, fedramp = nextAccount, nextPlan or "", nextFedramp
	end
	if type(accountId) ~= "string" or accountId == "" then
		return false, "The ChatGPT login did not identify an account."
	end
	setSetting(KEY_ACCESS_TOKEN, accessToken)
	setSetting(KEY_REFRESH_TOKEN, refreshToken)
	setSetting(KEY_ACCOUNT_ID, accountId)
	setSetting(KEY_PLAN_TYPE, type(plan) == "string" and plan or "")
	setSetting(KEY_FEDRAMP, fedramp)
	setSetting(KEY_EXPIRES_AT, jwtExpiry(accessToken) or (os.time() + 3600))
	setSetting(KEY_LEGACY_API_KEY, "")
	return true, nil
end

local function Initialize(pluginRef: any)
	plugin = pluginRef
	-- This migration is intentional and irreversible inside the plugin settings:
	-- the old value could authorize separately billed Platform API requests.
	setSetting(KEY_LEGACY_API_KEY, "")
end

local function startLogin(): {
	authorizeUrl: string,
	state: string,
	userCode: string,
	waitForApproval: boolean,
}
	if not plugin then error("Plugin not initialized.", 0) end
	clearDevice()
	local response, requestErr = postJson(DEVICE_USER_CODE_URL, { client_id = CLIENT_ID })
	if not response then error("device login request failed: " .. tostring(requestErr), 0) end
	if response.StatusCode < 200 or response.StatusCode >= 300 then
		error(responseError("device login", response), 0)
	end
	local parsed = jsonBody(response)
	local deviceAuthId = type(parsed) == "table" and parsed.device_auth_id or nil
	local userCode = type(parsed) == "table" and (parsed.user_code or parsed.usercode) or nil
	local interval = type(parsed) == "table" and tonumber(parsed.interval) or nil
	if type(deviceAuthId) ~= "string" or type(userCode) ~= "string" then
		error("device login returned an invalid response.", 0)
	end
	setSetting(KEY_DEVICE_AUTH_ID, deviceAuthId)
	setSetting(KEY_DEVICE_USER_CODE, userCode)
	setSetting(KEY_DEVICE_INTERVAL, math.clamp(interval or 5, 1, 30))
	setSetting(KEY_DEVICE_STARTED_AT, os.time())
	return {
		authorizeUrl = DEVICE_VERIFY_URL,
		state = deviceAuthId,
		userCode = userCode,
		waitForApproval = true,
	}
end

local function pollForAuthorization(): (any?, string?)
	local deviceAuthId = getSetting(KEY_DEVICE_AUTH_ID)
	local userCode = getSetting(KEY_DEVICE_USER_CODE)
	local interval = tonumber(getSetting(KEY_DEVICE_INTERVAL)) or 5
	local startedAt = tonumber(getSetting(KEY_DEVICE_STARTED_AT)) or 0
	if type(deviceAuthId) ~= "string" or deviceAuthId == ""
		or type(userCode) ~= "string" or userCode == "" then
		return nil, "No device login is in progress. Use /login first."
	end
	if os.time() - startedAt >= DEVICE_TIMEOUT_SECONDS then
		clearDevice()
		return nil, "The one-time code expired. Use /login to start again."
	end

	while os.time() - startedAt < DEVICE_TIMEOUT_SECONDS do
		-- /logout or a newer /login replaces the stored flow. Do not let an older
		-- polling task come back later and silently sign the user in again.
		if getSetting(KEY_DEVICE_AUTH_ID) ~= deviceAuthId
			or getSetting(KEY_DEVICE_USER_CODE) ~= userCode then
			return nil, "The device login was cancelled or replaced."
		end
		local response, requestErr = postJson(DEVICE_TOKEN_URL, {
			device_auth_id = deviceAuthId,
			user_code = userCode,
		})
		if not response then return nil, "device authorization failed: " .. tostring(requestErr) end
		if response.StatusCode >= 200 and response.StatusCode < 300 then
			local parsed = jsonBody(response)
			if type(parsed) ~= "table" then return nil, "device authorization returned invalid JSON" end
			return parsed, nil
		end
		if response.StatusCode ~= 403 and response.StatusCode ~= 404 then
			return nil, responseError("device authorization", response)
		end
		task.wait(math.clamp(interval, 1, 30))
	end
	clearDevice()
	return nil, "The one-time code expired. Use /login to start again."
end

local function completeLogin(pastedCode: string): (boolean, string?)
	local expected = getSetting(KEY_DEVICE_USER_CODE)
	local given = pastedCode:match("^%s*(.-)%s*$") or ""
	if given:match("^sk%-") then
		return false, "API keys are not accepted. Use the one-time ChatGPT code shown by /login."
	end
	if type(expected) ~= "string" or expected == "" then
		return false, "No device login is in progress. Use /login first."
	end
	if given:upper() ~= expected:upper() then
		return false, "That is not the one-time code shown by /login."
	end

	local authorization, authorizationErr = pollForAuthorization()
	if not authorization then return false, authorizationErr end
	local code = authorization.authorization_code
	local verifier = authorization.code_verifier
	if type(code) ~= "string" or type(verifier) ~= "string" then
		return false, "device authorization did not return an authorization code"
	end
	local response, requestErr = postForm(TOKEN_URL, {
		{ "grant_type", "authorization_code" },
		{ "code", code },
		{ "redirect_uri", DEVICE_REDIRECT_URI },
		{ "client_id", CLIENT_ID },
		{ "code_verifier", verifier },
	})
	if not response then return false, "token exchange failed: " .. tostring(requestErr) end
	if response.StatusCode < 200 or response.StatusCode >= 300 then
		return false, responseError("token exchange", response)
	end
	local tokens = jsonBody(response)
	if type(tokens) ~= "table" or type(tokens.access_token) ~= "string"
		or type(tokens.refresh_token) ~= "string" or type(tokens.id_token) ~= "string" then
		return false, "token exchange returned an invalid response"
	end
	-- A fresh device login is allowed to replace stale or partially-written state
	-- from another account. Refreshes below are not: silently switching accounts
	-- in the middle of a session would attach history to the wrong workspace.
	local saved, saveErr = saveTokens(tokens.access_token, tokens.refresh_token, tokens.id_token, false)
	if saved then clearDevice() end
	return saved, saveErr
end

local function isLoggedIn(): boolean
	return type(getSetting(KEY_ACCESS_TOKEN)) == "string"
		and getSetting(KEY_ACCESS_TOKEN) ~= ""
		and type(getSetting(KEY_REFRESH_TOKEN)) == "string"
		and getSetting(KEY_REFRESH_TOKEN) ~= ""
		and type(getSetting(KEY_ACCOUNT_ID)) == "string"
		and getSetting(KEY_ACCOUNT_ID) ~= ""
end

local function refresh(): (boolean, string?)
	local refreshToken = getSetting(KEY_REFRESH_TOKEN)
	if type(refreshToken) ~= "string" or refreshToken == "" then
		return false, "No ChatGPT refresh token. Use /login."
	end
	local response, requestErr = postJson(TOKEN_URL, {
		client_id = CLIENT_ID,
		grant_type = "refresh_token",
		refresh_token = refreshToken,
	})
	if not response then return false, "token refresh failed: " .. tostring(requestErr) end
	if response.StatusCode < 200 or response.StatusCode >= 300 then
		return false, responseError("token refresh", response)
	end
	local tokens = jsonBody(response)
	if type(tokens) ~= "table" then return false, "token refresh returned invalid JSON" end
	local accessToken = type(tokens.access_token) == "string" and tokens.access_token
		or getSetting(KEY_ACCESS_TOKEN)
	local nextRefresh = type(tokens.refresh_token) == "string" and tokens.refresh_token or refreshToken
	local idToken = type(tokens.id_token) == "string" and tokens.id_token or nil
	if type(accessToken) ~= "string" or accessToken == "" then
		return false, "token refresh did not return an access token"
	end
	return saveTokens(accessToken, nextRefresh, idToken, true)
end

local function getAccessToken(): (string?, string?)
	if not isLoggedIn() then
		return nil, "Not logged in. Use /login and authorize with your ChatGPT account."
	end
	local expiresAt = tonumber(getSetting(KEY_EXPIRES_AT)) or 0
	if expiresAt <= os.time() + REFRESH_WINDOW_SECONDS then
		local ok, err = refresh()
		if not ok then return nil, err end
	end
	local token = getSetting(KEY_ACCESS_TOKEN)
	if type(token) ~= "string" or token == "" then
		return nil, "ChatGPT access token is missing."
	end
	return token, nil
end

local function getAccountId(): string?
	local accountId = getSetting(KEY_ACCOUNT_ID)
	return if type(accountId) == "string" and accountId ~= "" then accountId else nil
end

local function isFedramp(): boolean
	return getSetting(KEY_FEDRAMP) == true
end

local function saveRateLimits(snapshot: any)
	if not plugin or type(snapshot) ~= "table" then return end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(snapshot) end)
	if ok then setSetting(KEY_RATE_LIMITS, encoded) end
	if type(snapshot.plan_type) == "string" and snapshot.plan_type ~= "" then
		setSetting(KEY_PLAN_TYPE, snapshot.plan_type)
	end
end

local function updateUsage(event: any)
	if type(event) == "table" and event.type == "codex.rate_limits" then saveRateLimits(event) end
end

local function headerValue(headers: string, name: string): string?
	local pattern = name:lower():gsub("%-", "%%-") .. ":%s*([^\r\n]+)"
	local value = headers:lower():match(pattern)
	return value and value:match("^%s*(.-)%s*$") or nil
end

local function headerWindow(headers: string, prefix: string): any?
	local used = tonumber(headerValue(headers, prefix .. "-used-percent") or "")
	if not used then return nil end
	return {
		used_percent = used,
		window_minutes = tonumber(headerValue(headers, prefix .. "-window-minutes") or ""),
		reset_at = tonumber(headerValue(headers, prefix .. "-reset-at") or ""),
	}
end

local function updateUsageHeaders(headers: string?)
	if type(headers) ~= "string" or headers == "" then return end
	local primary = headerWindow(headers, "x-codex-primary")
	local secondary = headerWindow(headers, "x-codex-secondary")
	local hasCredits = headerValue(headers, "x-codex-credits-has-credits")
	if not primary and not secondary and not hasCredits then return end
	local unlimited = headerValue(headers, "x-codex-credits-unlimited")
	local credits = if hasCredits then {
		has_credits = hasCredits == "true" or hasCredits == "1",
		unlimited = unlimited == "true" or unlimited == "1",
		balance = headerValue(headers, "x-codex-credits-balance"),
	} else nil
	saveRateLimits({
		type = "codex.rate_limits",
		plan_type = getSetting(KEY_PLAN_TYPE),
		rate_limits = { primary = primary, secondary = secondary },
		credits = credits,
	})
end

local PLAN_NAMES: { [string]: string } = {
	free = "Free", plus = "Plus", pro = "Pro", business = "Business",
	enterprise = "Enterprise", edu = "Edu", team = "Team",
}

local function untilReset(resetAt: any): string
	if type(resetAt) ~= "number" then return "" end
	local seconds = resetAt - os.time()
	if seconds <= 0 then return "resets now" end
	if seconds < 3600 then return string.format("resets in %dm", math.floor(seconds / 60)) end
	if seconds < 86400 then
		return string.format("resets in %dh %dm", math.floor(seconds / 3600),
			math.floor(seconds % 3600 / 60))
	end
	return string.format("resets in %dd %dh", math.floor(seconds / 86400),
		math.floor(seconds % 86400 / 3600))
end

local function windowLabel(kind: string, minutes: any): string
	if kind == "primary" and minutes == 300 then return "Session (5h)" end
	if kind == "secondary" and minutes == 10080 then return "Weekly" end
	if type(minutes) == "number" and minutes > 0 then
		if minutes % 1440 == 0 then return string.format("%s (%dd)", kind, minutes / 1440) end
		if minutes % 60 == 0 then return string.format("%s (%dh)", kind, minutes / 60) end
		return string.format("%s (%dm)", kind, minutes)
	end
	return kind
end

local function addWindow(rows: { UsageRow }, kind: string, window: any)
	if type(window) ~= "table" or type(window.used_percent) ~= "number" then return end
	local used = math.clamp(window.used_percent, 0, 100)
	rows[#rows + 1] = {
		label = windowLabel(kind, window.window_minutes),
		value = untilReset(window.reset_at),
		bar = used / 100,
		barValue = string.format("%d%% used", math.floor(used + 0.5)),
	}
end

local function fetchUsage(): ({ UsageRow }?, string?)
	local token, tokenErr = getAccessToken()
	if not token then return nil, tokenErr end
	local rows: { UsageRow } = {}
	local plan = getSetting(KEY_PLAN_TYPE)
	if type(plan) == "string" and plan ~= "" then
		rows[#rows + 1] = { label = "Plan", value = PLAN_NAMES[plan:lower()] or plan }
	end
	local encoded = getSetting(KEY_RATE_LIMITS)
	local snapshot
	if type(encoded) == "string" and encoded ~= "" then
		pcall(function() snapshot = HttpService:JSONDecode(encoded) end)
	end
	local limits = type(snapshot) == "table" and snapshot.rate_limits or nil
	if type(limits) == "table" then
		addWindow(rows, "primary", limits.primary)
		addWindow(rows, "secondary", limits.secondary)
	end
	local credits = type(snapshot) == "table" and snapshot.credits or nil
	if type(credits) == "table" and credits.has_credits == true then
		local value = if credits.unlimited == true then "unlimited"
			elseif type(credits.balance) == "string" and credits.balance ~= ""
			then credits.balance .. " remaining" else "available"
		rows[#rows + 1] = { label = "Codex credits", value = value }
	end
	if #rows == 0 or (#rows == 1 and rows[1].label == "Plan") then
		rows[#rows + 1] = { label = "Limits", value = "update after the first response" }
	end
	return rows, nil
end

local function logout()
	clearTokens()
end

return {
	Initialize = Initialize,
	startLogin = startLogin,
	completeLogin = completeLogin,
	isLoggedIn = isLoggedIn,
	getAccessToken = getAccessToken,
	getAccountId = getAccountId,
	isFedramp = isFedramp,
	updateUsage = updateUsage,
	updateUsageHeaders = updateUsageHeaders,
	fetchUsage = fetchUsage,
	logout = logout,
	refresh = refresh,
	tokenExpiry = function(): number? return tonumber(getSetting(KEY_EXPIRES_AT)) end,
	DEVICE_VERIFY_URL = DEVICE_VERIFY_URL,
}
