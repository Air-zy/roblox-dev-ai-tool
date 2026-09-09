--!strict
-- Diff.luau: line alignment, and where the changed regions sit.
--
-- Pure text. Two arrays of lines in, an edit script out; it knows nothing about
-- instances, flags, or how the result is drawn. `diff`'s -w/-b/-i stay with the
-- shell, because they are that command's options and not properties of an
-- alignment, and the unified `@@` formatting stays with whoever is printing.
--
-- Split out of Shell so the tool-call review can render the same alignment. The
-- alternative was scraping a formatted shell result back into structure, which
-- would make the console's diff depend on the exact spelling of `diff`'s output.

local Diff = {}

-- One aligned position: a context line carries both indices, a removal only
-- `a`, an addition only `b`.
export type Op = { op: string, a: number?, b: number? }

-- A real longest-common-subsequence diff. This used to walk both files by index
-- and call every position where they disagreed a change, so inserting ONE line
-- at the top of a 400-line module reported all 400 as different, a result that
-- is not merely noisy but wrong about which lines changed. None of -u, -b or -w
-- can be built honestly on top of that, because none of them mean anything
-- until the aligner knows which lines correspond to which.
--
-- ponytail: classic O(n*m) dynamic-programming table over the differing middle
-- only. The common prefix and suffix are trimmed first, so the quadratic part
-- sees the edit rather than the file, which is what keeps it cheap for the case
-- that actually happens. Ceiling: MAX_DIFF_LINES of genuinely differing text,
-- past which it reports the size instead of allocating; Myers' algorithm is the
-- upgrade path if that is ever hit in practice.
local MAX_DIFF_LINES = 1200

-- Align two line arrays. `key` decides what counts as the same line, so a caller
-- that folds case or whitespace passes that in rather than pre-mangling the text
-- it wants printed.
function Diff.align(a: { string }, b: { string },
	key: (string) -> string): ({ Op }?, string?)
	local script: { Op } = {}

	-- Trim the common prefix, then the common suffix. For the usual shape of an
	-- edit: a few lines changed in a large file, this leaves almost nothing
	-- for the quadratic part below.
	local head = 0
	while head < #a and head < #b and key(a[head + 1]) == key(b[head + 1]) do
		head += 1
		script[#script + 1] = { op = " ", a = head, b = head }
	end
	local tail = 0
	while #a - tail > head and #b - tail > head
		and key(a[#a - tail]) == key(b[#b - tail]) do
		tail += 1
	end

	local n, m = #a - tail - head, #b - tail - head
	if n * m > MAX_DIFF_LINES * MAX_DIFF_LINES then
		return nil, string.format("%d and %d lines differ — too much to align. " ..
			"Diff a narrower range, or grep for what changed.", n, m)
	end

	-- lengths[i][j] is the LCS length of a[i..n] against b[j..m], built from the
	-- far end so the backtrack below can walk forwards and emit in file order.
	local lengths: { { number } } = {}
	for i = n + 1, 1, -1 do
		local row: { number } = {}
		lengths[i] = row
		for j = m + 1, 1, -1 do
			if i > n or j > m then
				row[j] = 0
			elseif key(a[head + i]) == key(b[head + j]) then
				row[j] = lengths[i + 1][j + 1] + 1
			else
				row[j] = math.max(lengths[i + 1][j], row[j + 1])
			end
		end
	end

	local i, j = 1, 1
	while i <= n and j <= m do
		if key(a[head + i]) == key(b[head + j]) then
			script[#script + 1] = { op = " ", a = head + i, b = head + j }
			i += 1
			j += 1
		elseif lengths[i + 1][j] >= lengths[i][j + 1] then
			script[#script + 1] = { op = "-", a = head + i }
			i += 1
		else
			script[#script + 1] = { op = "+", b = head + j }
			j += 1
		end
	end
	while i <= n do
		script[#script + 1] = { op = "-", a = head + i }
		i += 1
	end
	while j <= m do
		script[#script + 1] = { op = "+", b = head + j }
		j += 1
	end
	for k = 1, tail do
		script[#script + 1] = { op = " ", a = #a - tail + k, b = #b - tail + k }
	end
	return script, nil
end

-- Group changes whose context windows touch, into `@@` hunks. Indices are into
-- `script`, not into either file: the caller already holds the ops and reads the
-- line numbers off them.
function Diff.hunks(script: { Op }, context: number): { { first: number, last: number } }
	local hunks: { { first: number, last: number } } = {}
	for index, op in ipairs(script) do
		if op.op ~= " " then
			local last = hunks[#hunks]
			if last and index - last.last <= context * 2 + 1 then
				last.last = index
			else
				hunks[#hunks + 1] = { first = index, last = index }
			end
		end
	end
	return hunks
end

-- The `@@` blocks for an aligned script, as lines. The `---`/`+++` file header
-- is NOT here: `diff` spells it one way, a tool-call review another, and the
-- hunks are the part they share.
function Diff.hunkText(script: { Op }, a: { string }, b: { string }, context: number): { string }
	local out: { string } = {}
	for _, hunk in ipairs(Diff.hunks(script, context)) do
		local from = math.max(1, hunk.first - context)
		local to = math.min(#script, hunk.last + context)
		local startA, startB, countA, countB = nil, nil, 0, 0
		local body: { string } = {}
		for index = from, to do
			local op = script[index]
			if op.a then
				startA = startA or op.a
				if op.op ~= "+" then
					countA += 1
				end
			end
			if op.b then
				startB = startB or op.b
				if op.op ~= "-" then
					countB += 1
				end
			end
			body[#body + 1] = op.op .. (op.op == "+" and b[op.b :: number] or a[op.a :: number])
		end
		out[#out + 1] = string.format("@@ -%d,%d +%d,%d @@",
			startA or 0, countA, startB or 0, countB)
		table.move(body, 1, #body, #out + 1, out)
	end
	return out
end

return Diff
