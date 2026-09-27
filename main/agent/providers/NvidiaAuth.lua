--!strict
--!optimize 2
-- NvidiaAuth.luau: NVIDIA NIM credentials, a pasted key (see KeyAuth), plus a
-- meter of our own sends. Keys expire after six months unless minted "Never
-- Expire", but no response says when.
--
-- Reference: https://build.nvidia.com/settings/api-keys

local KeyAuth = require(script.Parent:WaitForChild("KeyAuth"))

-- A reference point, not this account's limit: NVIDIA publishes none, 40/min is
-- the forum figure, and raised accounts get 200. One budget per KEY, not per model.
local FREE_RPM = 40

-- Our own sends, since no NVIDIA response carries a quota or rate-limit header.
-- ponytail: a plain array pruned on write, not a ring buffer; it holds at most a
-- minute of sends.
local RPM_WINDOW = 60
local sendTimes: { number } = {}

-- Once per attempt, retries included.
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

local auth = KeyAuth({
	settingKey = "nvidia_api_key",
	keysUrl = "https://build.nvidia.com/settings/api-keys",
	keysName = "NVIDIA keys",
	-- What we measured first, then the figure we can only quote.
	usage = function()
		local sent = recentRequests()
		return {
			{
				label = "Sent",
				value = string.format("%d in the last minute", sent),
				bar = math.clamp(sent / FREE_RPM, 0, 1),
			},
			{ label = "Key limit", value = string.format("~%d/min, unpublished", FREE_RPM) },
		}
	end,
})
-- The wire quotes these back on a 429.
auth.FREE_RPM = FREE_RPM
auth.noteRequest = noteRequest
auth.recentRequests = recentRequests
return auth
