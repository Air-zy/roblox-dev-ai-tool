--!strict
-- Pkce.luau: the PKCE primitives, shared by every provider that logs in.
--
-- RFC 7636. A verifier is high-entropy random; the challenge is
-- base64url(sha256(verifier)); the server compares them, which is what stops an
-- intercepted authorization code being redeemed by anyone but us.
--
-- Extracted when OpenRouter arrived and turned out to want the identical flow —
-- authorize in a browser, paste the code back — differing only in URLs and in
-- what comes back at the end. What is here is the part with no provider in it.

local Sha256 = require(script.Parent.Parent.Parent
	:WaitForChild("util"):WaitForChild("Sha256")) :: any

local HttpService = game:GetService("HttpService")

local Pkce = {}

-- A high-entropy code_verifier (the spec allows 43-128 chars; this is 43).
--
-- Roblox has no crypto RNG. GenerateGUID(false) returns a 32-hex-char GUID
-- without braces, so two of them concatenated is 64 hex chars = 256 bits, which
-- is what the spec recommends. Hex-decoded to 32 raw bytes, then base64url'd.
function Pkce.verifier(): string
	local hex = (HttpService:GenerateGUID(false) .. HttpService:GenerateGUID(false)):gsub("-", "")
	local bytes = {}
	for i = 1, #hex, 2 do
		bytes[#bytes + 1] = string.char(tonumber(string.sub(hex, i, i + 1), 16) :: number)
	end
	return Sha256.b64url(table.concat(bytes))
end

-- code_challenge = base64url(sha256(verifier)), always S256. `plain` is in the
-- spec and is not worth offering: it sends the verifier itself.
function Pkce.challenge(verifier: string): string
	return Sha256.base64url(verifier)
end

-- An opaque CSRF token. Any unguessable string works.
function Pkce.state(): string
	return (HttpService:GenerateGUID(false):gsub("-", ""))
end

-- Self-test
-- The vector is RFC 7636 appendix B, which is the whole point of pinning this:
-- a challenge that is merely well-formed still fails every login, and the
-- failure arrives from the server as an opaque `invalid_grant`.
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
