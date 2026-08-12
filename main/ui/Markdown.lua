--!strict
-- Markdown.luau: Markdown to a list of renderable blocks.
--
-- WHY THIS IS A PARSER AND NOT A STRING FORMATTER:
-- The first version turned a whole reply into one RichText string. Roblox's
-- RichText parser is all-or-nothing per label: if any tag anywhere in the string
-- is malformed or unsupported, it silently discards the markup and shows the
-- raw text, entities and all. One bad construct 40 lines down therefore breaks
-- headings at the top. RichText also can't draw a background, so a code block
-- could never look like a code block.
--
-- So block structure (headings, code blocks, quotes, lists, rules) is real GUI
-- objects, built by Console. RichText is used only for inline runs inside a
-- single paragraph, where it is the only way to mix weights in one wrapped
-- label: and where a failure degrades that one paragraph instead of the reply.

local Theme = require(script.Parent:WaitForChild("Theme"))

local Markdown = {}

local CODE_HEX = Theme.hex(Theme.CODE_CLR)

export type Block = {
	kind: string,       -- heading | paragraph | bullet | ordered | code | quote | rule | blank | table
	text: string,
	level: number?,     -- heading depth, or list indent depth
	marker: string?,    -- ordered-list number
	lang: string?,      -- code fence language
	rows: { { string } }?,  -- table cells, row 1 is the header
	align: { string }?,     -- per-column: left | center | right
}

-- Inline formatting
-- Only ever applied to a single paragraph's worth of text.
local function escape(s: string): string
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	return s
end
Markdown.escape = escape

-- Every rule matches a balanced pair, so a half-typed **, ` or ~~ mid-stream
-- stays literal rather than emitting a dangling tag that would blank the label.
function Markdown.inline(text: string): string
	text = escape(text)

	-- Anything stashed here is put back verbatim at the end, so it can't be
	-- re-matched by a later rule. \1..\2 can't occur in real text.
	local stash: { string } = {}
	local function keep(literal: string): string
		table.insert(stash, literal)
		return "\1" .. #stash .. "\2"
	end

	-- Backslash-escaped backtick first, so \` doesn't open a code span. Every
	-- other escape waits until after code spans are extracted, because a
	-- backslash inside `code` is literal, paths and patterns are full of them.
	text = text:gsub("\\`", function() return keep("`") end)

	text = text:gsub("`([^`]+)`", function(body)
		return keep(string.format('<font face="%s" color="%s">%s</font>',
			Theme.MONO_FACE, CODE_HEX, body))
	end)

	-- \* \_ \# \| ..., the character survives as content, invisible to the
	-- emphasis and table rules below. escape() already ran, so & < > are
	-- entities by now and get stashed in that form.
	text = text:gsub("\\(&%a+;)", function(entity) return keep(entity) end)
	text = text:gsub("\\(%p)", function(char) return keep(char) end)

	-- [label](url), keep the label, drop the URL. RichText has no links.
	text = text:gsub("%[([^%]]*)%]%b()", "%1")

	text = text:gsub("%*%*%*(.-)%*%*%*", "<b><i>%1</i></b>")
	text = text:gsub("%*%*(.-)%*%*", "<b>%1</b>")
	text = text:gsub("~~(.-)~~", "<s>%1</s>")
	text = text:gsub("%*([^%*]+)%*", "<i>%1</i>")
	text = text:gsub("__(.-)__", "<b>%1</b>")

	-- Restore repeatedly: a code span stashed in pass 2 may itself contain a
	-- placeholder from pass 1.
	local replaced: number
	repeat
		text, replaced = text:gsub("\1(%d+)\2", function(i)
			return stash[tonumber(i) :: number]
		end)
	until replaced == 0
	return text
end

-- Block parsing
-- A table row is any line containing a pipe; what makes it a TABLE is the
-- delimiter line under the header (|---|:--:|), so detection always needs to
-- look one line ahead.
local function splitCells(line: string): { string }
	local trimmed = line:match("^%s*(.-)%s*$") :: string
	trimmed = trimmed:gsub("^|", ""):gsub("|$", "")
	local cells: { string } = {}
	for cell in (trimmed .. "|"):gmatch("([^|]*)|") do
		table.insert(cells, (cell:match("^%s*(.-)%s*$")) :: string)
	end
	return cells
end

local function isDelimiterRow(line: string?): boolean
	if not line or not line:find("%-") then return false end
	return line:match("^%s*|?[%s:%-|]+|?%s*$") ~= nil
end

local function alignmentsFrom(line: string): { string }
	local align: { string } = {}
	for _, cell in ipairs(splitCells(line)) do
		local left = cell:sub(1, 1) == ":"
		local right = cell:sub(-1) == ":"
		if left and right then
			table.insert(align, "center")
		elseif right then
			table.insert(align, "right")
		else
			table.insert(align, "left")
		end
	end
	return align
end

local function isRule(line: string): boolean
	return line:match("^%s*%-%-%-+%s*$") ~= nil
		or line:match("^%s*%*%*%*+%s*$") ~= nil
		or line:match("^%s*___+%s*$") ~= nil
end

function Markdown.parse(md: string): { Block }
	md = md:gsub("\r\n", "\n")

	local lines: { string } = {}
	for line in (md .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end

	local blocks: { Block } = {}
	local paragraph: { string } = {}

	local function flush()
		if #paragraph > 0 then
			table.insert(blocks, { kind = "paragraph", text = table.concat(paragraph, " ") })
			table.clear(paragraph)
		end
	end

	local i = 1
	while i <= #lines do
		local line = lines[i]
		local fenceLang = line:match("^%s*```(.*)$")
		local hashes, headingText = line:match("^(#+)%s+(.*)$")
		local bulletIndent, bulletText = line:match("^(%s*)[-*+]%s+(.*)$")
		local orderIndent, orderMarker, orderText = line:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
		local quoteText = line:match("^%s*>%s?(.*)$")

		if fenceLang == nil and line:find("|", 1, true) and isDelimiterRow(lines[i + 1]) then
			flush()
			local align = alignmentsFrom(lines[i + 1])
			local rows: { { string } } = { splitCells(line) }
			i += 2
			while i <= #lines and lines[i]:find("|", 1, true) do
				table.insert(rows, splitCells(lines[i]))
				i += 1
			end
			i -= 1  -- the loop's trailing i += 1 consumes the last row
			table.insert(blocks, { kind = "table", text = "", rows = rows, align = align })

		elseif fenceLang then
			flush()
			-- Collect verbatim until the closing fence, or to the end of what has
			-- streamed in so far.
			local body: { string } = {}
			i += 1
			while i <= #lines and not lines[i]:match("^%s*```") do
				table.insert(body, lines[i])
				i += 1
			end
			table.insert(blocks, {
				kind = "code",
				text = table.concat(body, "\n"),
				lang = fenceLang ~= "" and fenceLang or nil,
			})

		elseif hashes then
			flush()
			table.insert(blocks, { kind = "heading", text = headingText, level = #hashes })

		elseif isRule(line) then
			flush()
			table.insert(blocks, { kind = "rule", text = "" })

		elseif quoteText then
			flush()
			-- Merge consecutive quote lines into one block.
			local parts = { quoteText }
			while i + 1 <= #lines do
				local nextQuote = lines[i + 1]:match("^%s*>%s?(.*)$")
				if not nextQuote then break end
				table.insert(parts, nextQuote)
				i += 1
			end
			table.insert(blocks, { kind = "quote", text = table.concat(parts, " ") })

		elseif bulletText then
			flush()
			table.insert(blocks, { kind = "bullet", text = bulletText, level = math.floor(#bulletIndent / 2) })

		elseif orderText then
			flush()
			table.insert(blocks, {
				kind = "ordered",
				text = orderText,
				marker = orderMarker,
				level = math.floor(#orderIndent / 2),
			})

		elseif line:match("^%s*$") then
			flush()
			if #blocks > 0 and blocks[#blocks].kind ~= "blank" then
				table.insert(blocks, { kind = "blank", text = "" })
			end

		else
			-- Soft-wrapped prose: consecutive lines join into one paragraph so the
			-- label wraps to its own width instead of keeping Claude's line breaks.
			table.insert(paragraph, line)
		end

		i += 1
	end

	flush()
	return blocks
end

-- Self-test
function Markdown.selfTest(): (boolean, string?)
	local function kinds(md: string): string
		local names: { string } = {}
		for _, b in ipairs(Markdown.parse(md)) do
			table.insert(names, b.kind)
		end
		return table.concat(names, ",")
	end

	local structure = {
		{ md = "# Title",                 want = "heading" },
		{ md = "| a | b |\n|---|---|\n| 1 | 2 |", want = "table" },
		-- A pipe with no delimiter row underneath is just prose.
		{ md = "a | b",                   want = "paragraph" },
		{ md = "###### Six",              want = "heading" },
		{ md = "plain text",              want = "paragraph" },
		{ md = "- a\n- b",                want = "bullet,bullet" },
		{ md = "1. a\n2. b",              want = "ordered,ordered" },
		{ md = "---",                     want = "rule" },
		{ md = "> quoted\n> more",        want = "quote" },
		{ md = "```lua\nx = 1\n```",      want = "code" },
		-- An unterminated fence must still be one code block, not stray prose.
		{ md = "```lua\nx = 1",           want = "code" },
		{ md = "a\n\nb",                  want = "paragraph,blank,paragraph" },
	}
	for _, case in ipairs(structure) do
		local got = kinds(case.md)
		if got ~= case.want then
			return false, string.format("%q parsed as %s, wanted %s", case.md, got, case.want)
		end
	end

	-- Code bodies are verbatim: no escaping, no inline formatting, no fence.
	local code = Markdown.parse("```lua\nlocal t = {a = 1 < 2} -- **not bold**\n```")[1]
	if code.text ~= "local t = {a = 1 < 2} -- **not bold**" then
		return false, "code body was altered: " .. code.text
	end
	if code.lang ~= "lua" then
		return false, "code lang not captured"
	end

	-- Tables -----------------------------------------------------------------
	local tbl = Markdown.parse("| Name | Qty |\n|:-----|----:|\n| Part | 3 |\n| Bolt | 12 |")[1]
	if tbl.kind ~= "table" then
		return false, "table not parsed, got " .. tbl.kind
	end
	if #(tbl.rows :: any) ~= 3 then
		return false, string.format("table has %d rows, wanted 3", #(tbl.rows :: any))
	end
	if (tbl.rows :: any)[1][1] ~= "Name" or (tbl.rows :: any)[3][2] ~= "12" then
		return false, "table cells misaligned"
	end
	if (tbl.align :: any)[1] ~= "left" or (tbl.align :: any)[2] ~= "right" then
		return false, "table alignment not read from the delimiter row"
	end

	local inlineCases = {
		{ input = "a < b & c", contains = "a &lt; b &amp; c" },
		{ input = "**b**",     contains = "<b>b</b>" },
		{ input = "~~s~~",     contains = "<s>s</s>" },
		{ input = "*i*",       contains = "<i>i</i>" },
		{ input = "`x<y`",     contains = "x&lt;y" },
		{ input = "[t](http://u)", contains = "t" },
		{ input = "**open",    absent = "<b>" },
		{ input = "`open",     absent = "<font" },
		{ input = "`a ** b`",  absent = "<b>" },
		-- Backslash escapes: the marker shows, the formatting does not.
		{ input = "\\*not italic\\*", contains = "*not italic*" },
		{ input = "\\*not italic\\*", absent = "<i>" },
		{ input = "\\**not bold\\**",  absent = "<b>" },
		{ input = "\\`not code\\`",    absent = "<font" },
		{ input = "a \\| b",            contains = "a | b" },
		-- A backslash inside a code span is literal, not an escape.
		{ input = "`C:\\path\\to`",     contains = "C:\\path\\to" },
	}
	for _, case in ipairs(inlineCases) do
		local got = Markdown.inline(case.input)
		if case.contains and not got:find(case.contains, 1, true) then
			return false, string.format("inline %q missing %q, got %q", case.input, case.contains, got)
		end
		if case.absent and got:find(case.absent, 1, true) then
			return false, string.format("inline %q should not contain %q, got %q", case.input, case.absent, got)
		end
	end

	-- Every streaming prefix of a realistic reply must leave tags balanced.
	local sample = "Here **bold** and `code`:\n\n```lua\nlocal t = {a = 1 < 2}\n```\n\n- one *two*\n\n## Done & dusted"
	for n = 1, #sample do
		for _, block in ipairs(Markdown.parse(sample:sub(1, n))) do
			if block.kind ~= "code" then
				local rich = Markdown.inline(block.text)
				for _, tag in ipairs({ "b", "i", "s", "font" }) do
					local _, opens = rich:gsub("<" .. tag .. "[ >]", "")
					local _, closes = rich:gsub("</" .. tag .. ">", "")
					if opens ~= closes then
						return false, string.format("prefix %d left <%s> unbalanced: %q", n, tag, rich)
					end
				end
			end
		end
	end

	return true, nil
end

return Markdown
