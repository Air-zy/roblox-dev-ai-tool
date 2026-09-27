--!strict
--!optimize 2
-- GeminiAuth.luau: Google AI Studio credentials, a pasted key (see KeyAuth).
--
-- A key can be restricted to particular APIs, so one valid elsewhere is refused
-- here without the Generative Language API; the wire's `explain` says so.
--
-- Reference: https://aistudio.google.com/apikey

local KeyAuth = require(script.Parent:WaitForChild("KeyAuth"))

-- The live per-minute and per-day numbers; there is no API for them.
local RATE_LIMIT_URL = "https://aistudio.google.com/rate-limit"

local auth = KeyAuth({
	settingKey = "gemini_api_key",
	keysUrl = "https://aistudio.google.com/apikey",
	keysName = "Google API keys",
	usage = function()
		return {
			{ label = "Rate limit", value = "per minute and per day, by model" },
			{ label = "Live numbers", value = RATE_LIMIT_URL },
		}
	end,
})
auth.RATE_LIMIT_URL = RATE_LIMIT_URL
return auth
