--!strict
--!optimize 2
-- SHA-256 in pure Luau
-- Implements FIPS 180-4 using bit32 + string.pack/unpack
-- Verified against FIPS test vectors in /scripts/verify_sha256.py
--
-- Public API:
--   Sha256.hash(message: string): string  -- 32-byte raw binary
--   Sha256.hex(message: string): string   -- 64-char lowercase hex
--   Sha256.base64url(message: string): string  -- URL-safe base64 of the hash
--   Sha256.hmac(key: string, message: string): string  -- raw HMAC-SHA256

local bit32 = bit32

local U32 = 0xFFFFFFFF -- mask used to wrap additions to 32 bits

-- First 32 bits of fractional parts of cube roots of first 64 primes (FIPS 180-4 section 4.2.2)
local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- Initial hash values: first 32 bits of fractional parts of square roots of first 8 primes
local H0 = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

-- Right-rotate a 32-bit value by n positions (n must be in [0,31])
local function rrot(x: number, n: number): number
	return bit32.rrotate(x, n)
end

-- Mask-and-wrap a sum to 32-bit unsigned
local function w(x: number): number
	return bit32.band(x, U32)
end

-- Compute SHA-256 of `message` (UTF-8 string), return 32 raw bytes as a string
local function hash(message: string): string
	-- Pre-processing: append 0x80, pad with 0x00 until length % 64 == 56, then 8-byte BE bit length
	local lenBytes = #message
	local bitLen = lenBytes * 8
	local padded = message .. "\128"
	local rem = #padded % 64
	local padNeeded = (56 - rem) % 64
	if padNeeded > 0 then
		padded = padded .. string.rep("\0", padNeeded)
	end
	-- 64-bit big-endian length. Roblox messages are < 2^53 bits so high 32 bits are always 0.
	-- string.pack(">I8", ...) expects an unsigned 64-bit value; we pass the bit length directly
	-- (it fits because messages are well under 2^53 bytes).
	padded = padded .. string.pack(">I8", bitLen)

	local h1, h2, h3, h4, h5, h6, h7, h8 =
		H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8]

	local W = table.create(64)

	for chunkStart = 1, #padded, 64 do
		-- Build message schedule W[0..63]
		for i = 0, 15 do
			W[i] = string.unpack(">I4", padded, chunkStart + i * 4)
		end
		for i = 16, 63 do
			local w15 = W[i - 15]
			local w2 = W[i - 2]
			local s0 = bit32.bxor(bit32.bxor(rrot(w15, 7), rrot(w15, 18)), bit32.rshift(w15, 3))
			local s1 = bit32.bxor(bit32.bxor(rrot(w2, 17), rrot(w2, 19)), bit32.rshift(w2, 10))
			W[i] = w(w(W[i - 16]) + s0 + w(W[i - 7]) + s1)
		end

		local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8

		for i = 0, 63 do
			local S1 = bit32.bxor(bit32.bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
			local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
			local t1 = w(w(w(w(h + S1) + ch) + K[i + 1]) + W[i])
			local S0 = bit32.bxor(bit32.bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
			local maj = bit32.bxor(bit32.bxor(bit32.band(a, b), bit32.band(a, c)), bit32.band(b, c))
			local t2 = w(S0 + maj)
			h = g
			g = f
			f = e
			e = w(d + t1)
			d = c
			c = b
			b = a
			a = w(t1 + t2)
		end

		h1 = w(h1 + a); h2 = w(h2 + b); h3 = w(h3 + c); h4 = w(h4 + d)
		h5 = w(h5 + e); h6 = w(h6 + f); h7 = w(h7 + g); h8 = w(h8 + h)
	end

	return string.pack(">I4I4I4I4I4I4I4I4", h1, h2, h3, h4, h5, h6, h7, h8)
end

-- 64-char lowercase hex of `message`'s SHA-256
local function hex(message: string): string
	local bin = hash(message)
	return (bin:gsub(".", function(c: string)
		return string.format("%02x", string.byte(c) :: number)
	end))
end

-- URL-safe Base64 (no padding) of the raw SHA-256 of `message`
local function base64url(message: string): string
	local bin = hash(message)
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	local out = {}
	local i = 1
	while i <= #bin do
		local b1 = string.byte(bin, i) :: number
		local b2 = string.byte(bin, i + 1) or 0
		local b3 = string.byte(bin, i + 2) or 0
		local n = b1 * 65536 + b2 * 256 + b3
		table.insert(out, string.sub(chars, math.floor(n / 262144) + 1, math.floor(n / 262144) + 1))
		table.insert(out, string.sub(chars, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))
		table.insert(out, string.sub(chars, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
		if i + 2 <= #bin then
			table.insert(out, string.sub(chars, n % 64 + 1, n % 64 + 1))
		end
		i = i + 3
	end
	return table.concat(out)
end

-- HMAC-SHA256(key, message) -> 32 raw bytes
-- Per RFC 2104: H((K' xor opad) || H((K' xor ipad) || message))
-- where K' is K padded/hashed to 64 bytes, ipad=0x36*64, opad=0x5C*64
local function hmac(key: string, message: string): string
	local blockSize = 64
	if #key > blockSize then
		key = hash(key)
	end
	key = key .. string.rep("\0", blockSize - #key)

	local ipad = string.rep("\36", blockSize) -- 0x36
	local opad = string.rep("\92", blockSize) -- 0x5C

	-- XOR key with ipad/opad
	local keyIpad = {}
	local keyOpad = {}
	for i = 1, blockSize do
		local k = string.byte(key, i) :: number
		local ip = string.byte(ipad, i) :: number
		local op = string.byte(opad, i) :: number
		keyIpad[i] = string.char(bit32.bxor(k, ip))
		keyOpad[i] = string.char(bit32.bxor(k, op))
	end
	keyIpad = table.concat(keyIpad)
	keyOpad = table.concat(keyOpad)

	local inner = hash(keyIpad .. message)
	return hash(keyOpad .. inner)
end

return {
	hash = hash,
	hex = hex,
	base64url = base64url,
	hmac = hmac,
}
