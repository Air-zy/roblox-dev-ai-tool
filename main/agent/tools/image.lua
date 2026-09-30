-- image: see a picture, by asset id or from the object that shows it.
--
-- The pixels come from the asset's thumbnail (rbxthumb://), not the asset:
-- CreateEditableImageAsync only loads an image asset the place's creator owns,
-- and the decals worth asking about mostly came from someone else. They come
-- back raw and EncodingService compresses Zstd only, so the PNG is written by
-- hand below with stored (uncompressed) deflate blocks. Valid, not small: about
-- 700 KB at 420x420, which the model reads as ~225 tokens.

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")
local Props = require(script.Parent.Parent.Parent:WaitForChild("studio"):WaitForChild("Props"))

local SIZE = 420

-- The id in an asset URL, or nil: a built-in rbxasset:// path has none to
-- thumbnail. URLs only, because this also reads every string property, and a
-- TextLabel whose Text is "5" is not asset 5.
local function urlId(value: string): string?
	return value:match("rbxassetid://(%d+)") or value:match("[?&]id=(%d+)")
end

-- Asset ids that are not pictures. Skipped by name rather than listing the
-- picture ones, which Shirt (ShirtTemplate), ShirtGraphic (Graphic), Sky
-- (SkyboxBk...) and the rest spell differently; MeshId sorts ahead of TextureId.
local function notPicture(prop: string): boolean
	return prop:find("Mesh") ~= nil or prop:find("Sound") ~= nil
		or prop:find("Animation") ~= nil or prop:find("Video") ~= nil
end

-- The first property holding a picture's asset URL, walked in the API dump's
-- order (the one `cat` prints), as (id, property) or (nil, why not).
local function imageOf(inst: Instance): (string?, string?)
	local names, err = Props.names(inst.ClassName)
	if not names then return nil, err end
	local builtin: string? = nil
	for _, prop in ipairs(names) do
		if not notPicture(prop) then
			local ok, value = pcall(function() return (inst :: any)[prop] end)
			if ok and type(value) == "string" and value ~= "" then
				local id = urlId(value)
				if id then return id, prop end
				if value:match("^rbxasset://") then builtin = builtin or (prop .. " = " .. value) end
			end
		end
	end
	return nil, if builtin
		then builtin .. ", a built-in file with no asset id"
		else "no picture asset in any of its properties"
end

-- (id, what the text line should call it) or (nil, error).
local function idFor(term: any, source: string): (string?, string?)
	local id = source:match("^%s*(%d+)%s*$") or urlId(source)
	if id then return id, "asset " .. id end
	local inst, err = term:resolve(source)
	if not inst then return nil, err or ("no such object: " .. source) end
	local found, from = imageOf(inst)
	if not found then return nil, inst.Name .. ": " .. tostring(from) end
	return found, string.format("%s.%s, asset %s", inst.Name, tostring(from), found)
end

-- PNG
local CRC: { number } = table.create(256, 0)
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		c = if bit32.band(c, 1) == 1 then bit32.bxor(0xEDB88320, bit32.rshift(c, 1)) else bit32.rshift(c, 1)
	end
	CRC[n + 1] = c
end

local function crc32(b: buffer, from: number, count: number): number
	local c = 0xFFFFFFFF
	for i = from, from + count - 1 do
		c = bit32.bxor(CRC[bit32.band(bit32.bxor(c, buffer.readu8(b, i)), 0xFF) + 1], bit32.rshift(c, 8))
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

local function writeBE(b: buffer, at: number, value: number)
	buffer.writeu32(b, at, bit32.byteswap(value))
end

-- RGBA8 pixels, row-major, as PNG bytes. A stored deflate block holds at most
-- 65535 bytes, so the scanlines are split across as many as it takes.
local function png(pixels: buffer, width: number, height: number): buffer
	local row = width * 4
	local rawLen = height * (row + 1)
	-- Zero-filled, so each scanline's filter byte is already 0 (None).
	local raw = buffer.create(rawLen)
	for y = 0, height - 1 do
		buffer.copy(raw, y * (row + 1) + 1, pixels, y * row, row)
	end
	local a, s = 1, 0
	for i = 0, rawLen - 1 do
		a = (a + buffer.readu8(raw, i)) % 65521
		s = (s + a) % 65521
	end

	local blocks = math.max(1, math.ceil(rawLen / 65535))
	local idatLen = 2 + rawLen + 5 * blocks + 4
	local out = buffer.create(8 + 25 + 12 + idatLen + 12)
	buffer.writestring(out, 0, "\137PNG\r\n\26\n")
	local at = 8
	local function chunk(kind: string, length: number, fill: (number) -> ())
		writeBE(out, at, length)
		buffer.writestring(out, at + 4, kind)
		fill(at + 8)
		writeBE(out, at + 8 + length, crc32(out, at + 4, length + 4))
		at += 12 + length
	end

	chunk("IHDR", 13, function(p)
		writeBE(out, p, width)
		writeBE(out, p + 4, height)
		buffer.writeu8(out, p + 8, 8) -- bit depth; compression, filter, interlace stay 0
		buffer.writeu8(out, p + 9, 6) -- colour type RGBA
	end)
	chunk("IDAT", idatLen, function(p)
		buffer.writeu8(out, p, 0x78) -- zlib header, no dictionary
		buffer.writeu8(out, p + 1, 0x01)
		p += 2
		for n = 0, blocks - 1 do
			local from = n * 65535
			local len = math.min(65535, rawLen - from)
			buffer.writeu8(out, p, if n == blocks - 1 then 1 else 0)
			buffer.writeu16(out, p + 1, len)
			buffer.writeu16(out, p + 3, bit32.bxor(len, 0xFFFF))
			buffer.copy(out, p + 5, raw, from, len)
			p += 5 + len
		end
		writeBE(out, p, s * 65536 + a)
	end)
	chunk("IEND", 0, function() end)
	return out
end

return {
	name = "image",
	description = "view an image: an asset id, or the path of an object showing one "
		.. "(Decal, Shirt, ImageLabel, MeshPart...). returns a 420x420 thumbnail",
	input_schema = {
		type = "object",
		properties = {
			source = { type = "string" },
		},
		required = { "source" },
	},
	images = true,
	run = function(term: any, input: { [string]: any }): any
		local id, what = idFor(term, tostring(input.source or ""))
		if not id then return "image: " .. tostring(what) end
		local uri = string.format("rbxthumb://type=Asset&id=%s&w=%d&h=%d", id, SIZE, SIZE)
		local ok, img = pcall(function()
			return AssetService:CreateEditableImageAsync(Content.fromUri(uri))
		end)
		if not ok then return string.format("image: asset %s did not load: %s", id, tostring(img)) end
		-- nil rather than an error is how the editable-image memory budget says no.
		if not img then return "image: out of editable-image memory, try again" end
		local size = img.Size
		local read, pixels = pcall(img.ReadPixelsBuffer, img, Vector2.zero, size)
		img:Destroy()
		if not read then return "image: " .. tostring(pixels) end
		return {
			{ type = "image", source = { type = "base64", media_type = "image/png",
				data = buffer.tostring(EncodingService:Base64Encode(png(pixels, size.X, size.Y))) } },
			{ type = "text", text = string.format("%s, %dx%d thumbnail", tostring(what), size.X, size.Y) },
		}
	end,
	-- The encoder against a reference Python's zlib wrote (level 0 is this same
	-- stored layout), the id forms a property actually holds, and which property
	-- wins on the two classes that expose the rules. Needs the API dump, as
	-- Props' own test does.
	selfTest = function(): (boolean, string?)
		local pixels = buffer.create(16)
		for i, byte in ipairs({ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128 }) do
			buffer.writeu8(pixels, i - 1, byte)
		end
		local got = buffer.tostring(EncodingService:Base64Encode(png(pixels, 2, 2)))
		if got ~= "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAHUlEQVR4AQESAO3/AP8AAP8A/wD/AAAA//////+ASUkJeEvZzgMAAAAASUVORK5CYII=" then
			return false, "PNG encoder output differs from the reference"
		end
		if urlId("rbxassetid://123") ~= "123" or urlId("http://www.roblox.com/asset/?id=45") ~= "45"
			or urlId("5") ~= nil or urlId("rbxasset://textures/face.png") ~= nil then
			return false, "an asset id was misread"
		end
		local shirt = Instance.new("Shirt")
		shirt.ShirtTemplate = "http://www.roblox.com/asset/?id=13916825311"
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshId = "rbxassetid://1"
		mesh.TextureId = "rbxassetid://2"
		local shirtId, shirtProp = imageOf(shirt)
		local meshId = imageOf(mesh)
		shirt:Destroy()
		mesh:Destroy()
		if shirtId ~= "13916825311" or shirtProp ~= "ShirtTemplate" then
			return false, "a Shirt's picture was not found: " .. tostring(shirtProp)
		end
		if meshId ~= "2" then
			return false, "a SpecialMesh answered with its mesh, not its texture"
		end
		return true
	end,
}
