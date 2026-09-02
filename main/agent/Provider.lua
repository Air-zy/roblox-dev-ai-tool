--!strict
-- The active provider. Nothing outside providers/ names a vendor.
--
-- `wire` sends one request and streams the reply; `auth` owns login and tokens.
-- A third provider is a third pair of files plus an entry in REGISTRY.
--
-- Read `Provider.wire.x` at the point of use, never `local Wire = Provider.wire`
-- at the top of a file: the pair below is REPLACED when the user switches, and
-- a reference captured at require time would go on talking to the old one.
--
-- History is provider-shaped: thinking blocks carry signatures only their own
-- provider can read, so a session is bound to the provider that created it and
-- a cross-provider restore is refused rather than silently corrupted.
local providers = script.Parent:WaitForChild("providers")

local Provider = {}

-- label and hint are what the picker shows. Nothing else in the codebase gets
-- to know these names.
local REGISTRY: { [string]: { label: string, hint: string, wire: string, auth: string } } = {
	anthropic = {
		label = "Claude",
		hint = "subscription",
		wire = "Anthropic",
		auth = "AnthropicAuth",
	},
	openrouter = {
		label = "OpenRouter",
		hint = "free models",
		wire = "OpenRouter",
		auth = "OpenRouterAuth",
	},
}
-- Fixed order, so the picker does not reshuffle between launches.
local ORDER = { "anthropic", "openrouter" }

local KEY_PROVIDER = "cc_provider"
local DEFAULT_PROVIDER = "anthropic"

local pluginRef: any = nil

Provider.id = DEFAULT_PROVIDER
Provider.wire = nil :: any
Provider.auth = nil :: any

-- { { id, label, hint } }, in a stable order, for the settings picker.
function Provider.list(): { { id: string, label: string, hint: string } }
	local out = {}
	for _, id in ipairs(ORDER) do
		local entry = REGISTRY[id]
		out[#out + 1] = { id = id, label = entry.label, hint = entry.hint }
	end
	return out
end

function Provider.label(id: string?): string
	local entry = REGISTRY[id or Provider.id]
	return if entry then entry.label else tostring(id)
end

-- Swaps in a provider and initialises it. The caller is responsible for
-- resetting the agent afterwards: the conversation in memory is shaped by
-- whichever provider produced it, and Provider cannot require Agent — Agent
-- requires Provider.
function Provider.use(id: string): boolean
	local entry = REGISTRY[id]
	if not entry then return false end

	Provider.id = id
	Provider.wire = require(providers:WaitForChild(entry.wire)) :: any
	Provider.auth = require(providers:WaitForChild(entry.auth)) :: any
	Provider.auth.Initialize(pluginRef)
	-- pluginRef as well as auth: a provider whose model list is fetched rather
	-- than hardcoded needs somewhere to cache it. One that does not care ignores
	-- the second argument.
	Provider.wire.Initialize(Provider.auth, pluginRef)

	-- Only on a real switch. `use` is also how Initialize applies the SAVED id,
	-- which wrote back the value it had just read — and a plugin's settings are
	-- one JSON object, so that is the whole store re-serialised on every load to
	-- store nothing. Same trap as Settings.setSystem and for the same reason.
	if pluginRef and pluginRef:GetSetting(KEY_PROVIDER) ~= id then
		pluginRef:SetSetting(KEY_PROVIDER, id)
	end
	return true
end

-- Every provider's tests, not only the live one. A translation bug in the
-- inactive provider would otherwise surface the moment somebody switches, which
-- is the worst time to find one; requiring a wire does not initialise it, so
-- this costs a module load and no network.
function Provider.selfTest(): (boolean, string?)
	local pkce = require(providers:WaitForChild("Pkce"))
	local pkceOk, pkceErr = pkce.selfTest()
	if not pkceOk then return false, "Pkce: " .. tostring(pkceErr) end

	for _, id in ipairs(ORDER) do
		local wire = require(providers:WaitForChild(REGISTRY[id].wire)) :: any
		if wire.selfTest then
			local ok, err = wire.selfTest()
			if not ok then return false, id .. ": " .. tostring(err) end
		end
	end
	return true
end

function Provider.Initialize(plugin: any)
	pluginRef = plugin
	local saved = plugin and plugin:GetSetting(KEY_PROVIDER)
	-- Validated rather than trusted: a saved id from a build that had a provider
	-- this one does not would otherwise leave `wire` nil and fail at send time,
	-- a long way from the cause.
	if type(saved) ~= "string" or not REGISTRY[saved] then
		saved = DEFAULT_PROVIDER
	end
	Provider.use(saved)
end

return Provider
