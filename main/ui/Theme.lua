--!strict
-- Theme.luau — palette, fonts, and the `make` helper.
--
-- Split out of the main script so Console, Settings and the plugin entry point
-- all read the same values instead of each keeping their own copy.

local Theme = {}

-- =============================================================================
-- Claude.ai dark mode palette
-- =============================================================================
Theme.BG_DARK     = Color3.fromRGB(26, 25, 24)    -- #1A1918 warm dark
Theme.BG_SURFACE  = Color3.fromRGB(38, 37, 36)    -- #262524 slightly lighter
Theme.BG_INPUT    = Color3.fromRGB(42, 41, 39)    -- #2A2927 input area
Theme.BG_CODE     = Color3.fromRGB(32, 31, 30)    -- #201F1E code block fill
Theme.BORDER      = Color3.fromRGB(61, 59, 54)    -- #3D3B36 warm border
Theme.TEXT_HI     = Color3.fromRGB(244, 243, 238) -- #F4F3EE cream
Theme.TEXT_MED    = Color3.fromRGB(168, 162, 154) -- #A8A29A warm gray
Theme.TEXT_LO     = Color3.fromRGB(107, 104, 98)  -- #6B6862 muted
Theme.ACCENT      = Color3.fromRGB(218, 119, 86)  -- #DA7756 terra cotta
Theme.ACCENT_HI   = Color3.fromRGB(193, 95, 60)   -- #C15F3C Crail
Theme.THINK_CLR   = Color3.fromRGB(184, 168, 156) -- #B8A89C warm light brown
Theme.CODE_CLR    = Color3.fromRGB(226, 183, 148) -- #E2B794 sand, for code spans
Theme.ERR_CLR     = Color3.fromRGB(229, 120, 110) -- #E5786E lighter red

-- =============================================================================
-- Fonts
-- =============================================================================
-- Enum.Font.Code (Source Code Pro) everywhere made prose hard to read at 13px.
-- Prose now uses BuilderSans — Roblox's current UI family, which has real
-- weights, so RichText <b> renders as an actual bold face rather than a
-- synthesized one. Code keeps a monospace family.
Theme.SANS      = Font.fromName("BuilderSans", Enum.FontWeight.Regular)
Theme.SANS_BOLD = Font.fromName("BuilderSans", Enum.FontWeight.Bold)
Theme.MONO      = Font.fromName("RobotoMono", Enum.FontWeight.Regular)

-- RichText's <font face="..."> takes an Enum.Font NAME, not a family asset, so
-- the markdown renderer needs this string form to switch into monospace mid-line.
Theme.MONO_FACE = "RobotoMono"

Theme.TEXT_SIZE = 14
Theme.SMALL_SIZE = 12

-- =============================================================================
-- make — build an Instance from a property table
-- =============================================================================
-- Properties that change how a LATER property is interpreted must be assigned
-- first. `pairs` order is undefined, so without this a TextLabel can receive
-- Text before RichText and never parse its markup — nondeterministically, which
-- is why markup rendered on some labels and not others.
local FIRST = { "RichText", "FontFace", "Font", "TextSize", "TextScaled" }
local IS_FIRST: { [string]: boolean } = {}
for _, key in ipairs(FIRST) do
	IS_FIRST[key] = true
end

function Theme.make(className: string, props: { [string]: any }): any
	local obj = Instance.new(className)
	for _, key in ipairs(FIRST) do
		if props[key] ~= nil then
			(obj :: any)[key] = props[key]
		end
	end
	for k, v in pairs(props) do
		if not IS_FIRST[k] then
			(obj :: any)[k] = v
		end
	end
	return obj
end

-- Convert a Color3 to the #RRGGBB form RichText attributes expect.
function Theme.hex(color: Color3): string
	return string.format("#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5))
end

return Theme
