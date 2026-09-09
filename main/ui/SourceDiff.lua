--!strict
-- SourceDiff.luau: a tool call's source changes, as text to draw.
--
-- Pure text, deliberately. Everything decided here — what changed, by how much,
-- which lines are worth showing first — runs without a DataModel or a widget, so
-- it is covered by the CLI regressions rather than only by looking at it.
--
-- ONE text box rather than one Instance per diff row. Rows would need their own
-- recycling and their own Instance budget the first time a call rewrites a large
-- script, and a selection cannot cross separate TextBoxes, so copying a hunk
-- would need a second control to exist at all. As text the whole review selects
-- in one gesture, hunks included. The cost is that no line can carry a
-- background colour, which is why every changed line keeps its own + or -
-- marker: the marker is the signal, not the decoration.

local Fs = require(script.Parent.Parent:WaitForChild("fs"):WaitForChild("Fs"))
local Diff = require(script.Parent.Parent:WaitForChild("text"):WaitForChild("Diff"))

local SourceDiff = {}

-- Three lines either side, which is what `diff -U3` and the reference
-- implementation both use.
local CONTEXT = 3

-- One script a call changed. `before`/`after` are the effective source either
-- side of that call, already newline-normalised by the write.
export type Change = {
	path: string,
	name: string,
	before: string,
	after: string,
	kind: string,   -- "created" | "modified" | "deleted"
}

export type File = {
	path: string,
	name: string,
	kind: string,
	added: number,
	removed: number,
	lines: { string },
}

-- Align one change and count it. A rewrite too large to align is a REVIEW state,
-- not a failed write: the source landed either way, so this reports the sizes it
-- can prove rather than inventing counts or drawing an empty panel.
local function build(change: Change): File
	local before = Fs.splitLines(change.before)
	local after = Fs.splitLines(change.after)
	local script = Diff.align(before, after, function(line)
		-- Identity: a review compares source exactly. `diff`'s -w/-b/-i are that
		-- command's options, and folding whitespace here would hide the one edit
		-- most likely to be a mistake.
		return line
	end)
	if not script then
		return {
			path = change.path, name = change.name, kind = change.kind,
			added = #after, removed = #before,
			lines = {
				string.format("Large rewrite - line alignment unavailable (%d lines before, %d after)",
					#before, #after),
			},
		}
	end
	local added, removed = 0, 0
	for _, op in ipairs(script) do
		if op.op == "+" then
			added += 1
		elseif op.op == "-" then
			removed += 1
		end
	end
	local lines = Diff.hunkText(script, before, after, CONTEXT)
	-- A created script with no source still has something to say. Without this it
	-- draws an empty box, which reads as a failure rather than as an empty file.
	if #lines == 0 and change.kind ~= "modified" then
		lines = { "(empty script)" }
	end
	return {
		path = change.path, name = change.name, kind = change.kind,
		added = added, removed = removed, lines = lines,
	}
end

function SourceDiff.files(changes: { Change }): { File }
	local out: { File } = {}
	for index, change in ipairs(changes) do
		out[index] = build(change)
	end
	return out
end

-- The header line. The SHORT name, because the block header truncates at its end
-- and a deep path there would push the counts off the row — which are the half
-- worth seeing at a glance. The full path leads the body, where it has a line to
-- itself.
function SourceDiff.summary(files: { File }): string
	local added, removed = 0, 0
	for _, file in ipairs(files) do
		added += file.added
		removed += file.removed
	end
	local counts = string.format("+%d -%d", added, removed)
	if #files == 1 then
		local mark = if files[1].kind == "created" then "(new) "
			elseif files[1].kind == "deleted" then "(deleted) "
			else ""
		return string.format("%s %s%s", files[1].name, mark, counts)
	end
	return string.format("%d scripts changed  %s", #files, counts)
end

-- The patch as rows, capped to `limit` of them. The second return is how many
-- the cap withheld, so the caller can offer the rest instead of truncating in
-- silence — a diff that quietly stops is one that cannot be trusted to be whole.
--
-- Rows rather than one string because each is drawn in its own colour, and a
-- Roblox TextBox has exactly one TextColor3. The caller reads the first
-- character to know which: `+`, `-`, `@`, or context.
--
-- Each script is headed by its full path and its own counts. That heading is
-- NOT `--- a/x` / `+++ b/x`: this is a receipt to read in a narrow panel, not a
-- patch to feed to `git apply`, and one line beats two for something no tool
-- consumes.
function SourceDiff.rows(files: { File }, limit: number?): ({ string }, number)
	local out: { string } = {}
	for index, file in ipairs(files) do
		if index > 1 then
			out[#out + 1] = ""
		end
		-- Counts per file only when there are several. With one, the header above
		-- already carries them and repeating them is noise in a narrow panel.
		out[#out + 1] = if #files > 1
			then string.format("%s  +%d -%d", file.path, file.added, file.removed)
			else file.path
		table.move(file.lines, 1, #file.lines, #out + 1, out)
	end
	if not limit or #out <= limit then
		return out, 0
	end
	local hidden = #out - limit
	table.move(out, 1, limit, 1, out)
	for index = #out, limit + 1, -1 do
		out[index] = nil
	end
	return out, hidden
end

-- The same patch as one string. Kept for tests and anything that wants the
-- whole thing in a single value.
function SourceDiff.body(files: { File }, limit: number?): (string, number)
	local out, hidden = SourceDiff.rows(files, limit)
	return table.concat(out, "\n"), hidden
end

-- Which colour a row is, from its first character. Returned as a name so the
-- palette stays in Theme and this file stays free of GUI types.
function SourceDiff.kindOf(row: string): string
	local first = row:sub(1, 1)
	if first == "+" then
		return "added"
	elseif first == "-" then
		return "removed"
	elseif first == "@" or first == "/" then
		return "meta"
	end
	return "context"
end

return SourceDiff
