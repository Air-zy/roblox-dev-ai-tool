--!strict
--!optimize 2
-- KeyAuth.luau: the auth module for a provider whose credential is a pasted API
-- key (Gemini, NVIDIA). `startLogin` hands back the page that mints one and
-- `completeLogin` stores what was pasted.
--
-- No prefix check: Gemini's "AIza" check refused every key Google issues now.
-- The first request validates a key, and the wire's `explain` says why it failed.

export type Row = { label: string, value: string, bar: number? }

return function(opts: {
	settingKey: string,   -- no dots, no backslashes: Plugin:SetSetting silently fails otherwise
	keysUrl: string,      -- a settings page, printed under "Open this URL in your browser"
	keysName: string,     -- "NVIDIA keys", for the refresh message
	usage: () -> { Row }, -- the settings panel's rows, drawn only when logged in
}): { [string]: any }
	local plugin: any = nil -- handed over by Initialize; the global is root-Script only

	local function getSetting(key: string): any
		if not plugin then return nil end
		return plugin:GetSetting(key)
	end

	local function isLoggedIn(): boolean
		local key = getSetting(opts.settingKey)
		return type(key) == "string" and key ~= ""
	end

	return {
		-- The wire names this page when a key is refused.
		API_KEYS_URL = opts.keysUrl,

		Initialize = function(pluginRef: any)
			plugin = pluginRef
		end,

		-- No flow to begin; `state` only matches the other auth modules' shape.
		startLogin = function(): { authorizeUrl: string, state: string }
			return { authorizeUrl = opts.keysUrl, state = "" }
		end,

		completeLogin = function(pasted: string): (boolean, string?)
			local key = pasted:match("^%s*(.-)%s*$") or ""
			if key == "" then
				return false, "No key given."
			end
			-- No key format has inner whitespace; a pasted sentence or URL does.
			if key:find("%s") then
				return false, "That has spaces in it, so it is not a key. Copy just the key from "
					.. opts.keysUrl
			end
			if not plugin then return false, "Plugin not initialized." end
			plugin:SetSetting(opts.settingKey, key)
			return true, nil
		end,

		isLoggedIn = isLoggedIn,

		-- (token, error), like AnthropicAuth. Never yields.
		getAccessToken = function(): (string?, string?)
			local key = getSetting(opts.settingKey)
			if type(key) ~= "string" or key == "" then
				return nil, "Not logged in. Use /login."
			end
			return key, nil
		end,

		refresh = function(): (boolean, string?)
			return false, opts.keysName .. " are not refreshable; mint a new one at " .. opts.keysUrl
		end,

		logout = function()
			if not plugin then return end
			plugin:SetSetting(opts.settingKey, "")
		end,

		-- No response carries an expiry; nil renders as "unknown".
		tokenExpiry = function(): number?
			return nil
		end,

		fetchUsage = function(): ({ Row }?, string?)
			if not isLoggedIn() then
				return nil, "Not logged in."
			end
			return opts.usage(), nil
		end,
	}
end
