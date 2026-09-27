--!strict
-- Pkce.luau: RFC 7636 primitives, shared by every provider that logs in.

local HttpService = game:GetService("HttpService")
local EncodingService = game:GetService("EncodingService")

local Pkce = {}

-- URL-safe base64, unpadded, of raw bytes.
local function b64url(bin: string): string
	local b64 = buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(bin)))
	return (b64:gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- 43 chars from 256 bits. Roblox has no crypto RNG, so the bits are two GUIDs.
function Pkce.verifier(): string
	local hex = (HttpService:GenerateGUID(false) .. HttpService:GenerateGUID(false)):gsub("-", "")
	local bytes = {}
	for i = 1, #hex, 2 do
		bytes[#bytes + 1] = string.char(tonumber(string.sub(hex, i, i + 1), 16) :: number)
	end
	return b64url(table.concat(bytes))
end

-- Always S256; `plain` would send the verifier itself.
function Pkce.challenge(verifier: string): string
	return b64url(EncodingService:ComputeStringHash(verifier, Enum.HashAlgorithm.Sha256))
end

-- An opaque CSRF token. Any unguessable string works.
function Pkce.state(): string
	return (HttpService:GenerateGUID(false):gsub("-", ""))
end

-- Self-test
-- RFC 7636 appendix B. A wrong challenge only shows up as `invalid_grant`.
function Pkce.selfTest(): (boolean, string?)
	local verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	local expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
	local got = Pkce.challenge(verifier)
	if got ~= expected then
		return false, string.format("RFC 7636 challenge vector: got %s, expected %s", got, expected)
	end
	-- 43 base64url chars out of 32 bytes, and nothing outside the alphabet — a
	-- `+` or `/` from a plain-base64 implementation is rejected by the server.
	local v = Pkce.verifier()
	if #v ~= 43 then
		return false, string.format("verifier is %d chars, expected 43", #v)
	end
	if v:match("[^A-Za-z0-9%-_]") then
		return false, "verifier contains characters outside the base64url alphabet"
	end
	if Pkce.verifier() == v then
		return false, "two verifiers came back identical"
	end
	return true
end

return Pkce
