--!strict
-- The active provider. Nothing outside providers/ names a vendor.
--
-- `wire` sends one request and streams the reply; `auth` owns login and tokens.
-- A second provider is a second pair of files plus a change to `active` here.
--
-- History is provider-shaped: thinking blocks carry signatures only their own
-- provider can read, so a session is bound to the provider that created it and
-- a cross-provider restore is refused rather than silently corrupted.
local providers = script.Parent:WaitForChild("providers")

local Provider = {}

Provider.id = "anthropic"
Provider.wire = require(providers:WaitForChild("Anthropic")) :: any
Provider.auth = require(providers:WaitForChild("AnthropicAuth")) :: any

function Provider.Initialize(pluginRef: any)
	Provider.auth.Initialize(pluginRef)
	Provider.wire.Initialize(Provider.auth)
end

return Provider
