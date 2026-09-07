--!optimize 2
-- Statement/pipeline/loop execution extracted from Shell. The command handlers
-- still own DataModel operations; this module owns shell state and byte streams.
local Syntax = require(script.Parent:WaitForChild("ShellSyntax"))
local Words = require(script.Parent:WaitForChild("ShellWords"))
local Builtins = require(script.Parent:WaitForChild("ShellBuiltins"))
local Runtime = {}

Runtime.COMMANDS = { ":", "true", "false", "printf", "read", "export", "unset", "local", "return", "break", "continue", "exit" }
-- Output is an ordered list of { fd, text } chunks rather than one stdout string
-- and one stderr string. Two strings cannot record that `echo a; cat missing;
-- echo b` wrote a, then the error, then b: replaying them stream by stream put
-- every diagnostic after every line of data, so the error appeared to come from
-- the last command rather than the middle one. Both streams reach the same
-- console, so the console needs the interleave and a pipe still takes fd 1 only.
local function result(out: string?, code: number?, err: string?): any
	local parts = {}
	if out ~= nil and out ~= "" then parts[#parts + 1] = { fd = 1, text = out } end
	if err ~= nil and err ~= "" then parts[#parts + 1] = { fd = 2, text = err } end
	return { parts = parts, code = code or 0 }
end

-- One stream read back out of an interleaved result.
local function text(r: any, fd: number): string
	local pieces = {}
	for _, part in ipairs(r.parts) do
		if part.fd == fd then pieces[#pieces + 1] = part.text end
	end
	return table.concat(pieces)
end
local function errorResult(err: any): any return result("", 2, "bash: " .. tostring(err) .. "\n") end
local function validName(name: string): boolean return name:match("^[%a_][%w_]*$") ~= nil end

-- POSIX special builtins. A prefix assignment in front of one PERSISTS after the
-- command, where in front of an ordinary command it is restored. The generic
-- restore ran for these too, so `C=temp export C=operand` put `outer` back --
-- undoing the operand that export itself had just written.
local SPECIAL = { [":"] = true, ["export"] = true, ["unset"] = true, ["local"] = true,
	["return"] = true, ["break"] = true, ["continue"] = true, ["exit"] = true }

-- A subshell and a pipeline stage each run in their own shell, so `exit`,
-- `return`, `break` and `continue` end THAT shell and go no further. Leaking the
-- flow outward made `( exit 5 ); echo after` swallow the rest of the line, which
-- is the one shape used to end a script early without ending the caller.
local function contained(r: any): any
	r.flow, r.levels = nil, nil
	return r
end
local function emit(parts: { any }, fd: number, value: string, budget: any)
	if value == "" then return end
	budget.bytes += #value
	if budget.bytes > 4000000 then error("shell output exceeds 4000000 bytes", 0) end
	parts[#parts + 1] = { fd = fd, text = value }
end

-- Copy a result's chunks onto a buffer in the order they were written. `only`
-- keeps a single stream, which is what a non-final pipeline stage needs.
local function absorb(parts: { any }, r: any, budget: any, only: number?)
	for _, part in ipairs(r.parts) do
		if only == nil or part.fd == only then emit(parts, part.fd, part.text, budget) end
	end
end

-- PWD and OLDPWD are ordinary exported variables that `cd` maintains, as they
-- are in bash: `PWD=/fake` changes what `$PWD` reads without moving the shell,
-- and the next cd puts the real path back. Nothing outside the shell moves the
-- cwd, so the seed here cannot go stale.
local function initialState(terminal: any): any
	return { vars = { HOME = "/", PWD = terminal:pwd() }, exported = { HOME = true, PWD = true },
		functions = {}, args = {}, status = 0, locals = {} }
end

local function fork(terminal: any): any
	local child = setmetatable(table.clone(terminal), getmetatable(terminal))
	local old = terminal.shellState
	child.shellState = {
		vars = table.clone(old.vars), exported = table.clone(old.exported), functions = table.clone(old.functions),
		args = table.clone(old.args), status = old.status, locals = {},
	}
	-- Function context crosses a fork: `local` and `return` are still valid in a
	-- subshell, a pipeline stage or a substitution written inside a function.
	-- Each scope's SAVE slots are copied, never shared, so a value the fork
	-- shadows cannot be restored over the parent's on the way out.
	for index, scope in ipairs(old.locals) do child.shellState.locals[index] = table.clone(scope) end
	return child
end

local function readLine(input: any, raw: boolean): (string, boolean, { [number]: boolean })
	local out, escaped = {}, {}
	while input.at <= #input.text do
		local c = input.text:sub(input.at, input.at); input.at += 1
		if c == "\n" then return table.concat(out), true, escaped end
		if c == "\\" and not raw and input.at <= #input.text then
			c = input.text:sub(input.at, input.at); input.at += 1
			if c ~= "\n" then out[#out + 1] = c; escaped[#out] = true end
		else out[#out + 1] = c end
	end
	return table.concat(out), false, escaped
end

local function execute(ast: any, terminal: any, api: any, budget: any, input: any, depth: number): any
	if depth > 32 then return errorResult("shell call depth exceeds 32") end
	local state = terminal.shellState
	local runList, runNode
	local loopDepth = 0
	local function tick()
		budget.steps -= 1
		if budget.steps < 0 then error("shell execution budget exceeded (10000 steps); shorten the loop", 0) end
		api.breathe()
	end
	local context = {
		vars = state.vars, args = state.args, status = function() return state.status end,
		list = function(path) return api.list(terminal, path) end,
		exists = function(path) return terminal:resolve(path) ~= nil end,
	}
	context.diagnostics = {}
	context.capture = function(source)
		local child = fork(terminal)
		local captured = execute(Syntax.parse(source), child, api, budget, { text = "", at = 1 }, depth + 1)
		context.captureStatus = captured.code
		-- Only stdout is substituted; a diagnostic is never interpolated as a
		-- filename or an argument. It used to ABORT the line instead, which threw
		-- away everything the line had already printed:
		--     printf 'BEFORE\n'; X="$(cat missing)"; printf 'SURVIVED\n'
		-- printed neither BEFORE nor SURVIVED. That made `X=$(cmd)` unsafe for any
		-- command that might warn, and the loss was silent. The text is queued for
		-- the enclosing command's stderr instead, where bash puts it.
		local diagnostics = text(captured, 2)
		if diagnostics ~= "" then context.diagnostics[#context.diagnostics + 1] = diagnostics end
		return text(captured, 1)
	end
	local function expand(word: any, mode: string?): { string }
		context.args = state.args
		return Words.expand(word.raw, context, mode)
	end
	local function builtin(argv: { string }, stream: any): any?
		local cmd = argv[1]
		if cmd == "true" or cmd == ":" then return result() end
		if cmd == "false" then return result("", 1) end
		if cmd == "printf" then
			local name, args = nil, argv
			if argv[2] == "-v" then
				name = argv[3]
				if not name or not validName(name) then return errorResult("printf -v requires a variable name") end
				args = { "printf" }; table.move(argv, 4, #argv, 2, args)
			end
			local out, err, code = Builtins.printf(args)
			if name then state.vars[name] = out; out = "" end
			return result(out, code or (err and 1 or 0), err and err .. "\n" or nil)
		end
		if cmd == "read" then
			local at, raw = 2, false
			while argv[at] and argv[at]:sub(1, 1) == "-" do
				if argv[at] == "--" then at += 1; break end
				if argv[at] ~= "-r" then return errorResult("read: unsupported option " .. argv[at]) end
				raw = true; at += 1
			end
			local names = {}; table.move(argv, at, #argv, 1, names)
			for _, name in ipairs(names) do if not validName(name) then return errorResult("read: invalid variable " .. name) end end
			local line, terminated, escaped = readLine(stream, raw)
			if #names == 0 then state.vars.REPLY = line
			else
				local ifs = state.vars.IFS
				if ifs == nil then ifs = " \t\n" end
				local position = 1
				local function separator(position)
					return position <= #line and not escaped[position] and ifs:find(line:sub(position, position), 1, true)
				end
				local function whitespace(position)
					return separator(position) and line:sub(position, position):find("[ \t\n]")
				end
				for index, name in ipairs(names) do
					while whitespace(position) do position += 1 end
					local start = position
					if index == #names then
						local finish = #line
						while finish >= start and whitespace(finish) do finish -= 1 end
						-- A single remaining field loses its delimiter. With multiple
						-- fields, read assigns the unsplit remainder to the last name.
						local fieldEnd = start
						while fieldEnd <= finish and not separator(fieldEnd) do fieldEnd += 1 end
						local nextField = fieldEnd
						while whitespace(nextField) do nextField += 1 end
						if separator(nextField) then nextField += 1 end
						while whitespace(nextField) do nextField += 1 end
						if nextField > finish then finish = fieldEnd - 1 end
						state.vars[name] = line:sub(start, finish)
					else
						while position <= #line and not separator(position) do position += 1 end
						state.vars[name] = line:sub(start, position - 1)
						while whitespace(position) do position += 1 end
						if separator(position) then position += 1 end
					end
				end
			end
			return result("", terminated and 0 or 1)
		end
		if cmd == "export" or cmd == "local" then
			local start = 2
			if argv[start] == "--" then start += 1 end
			if cmd == "local" and #state.locals == 0 then return errorResult("local: only valid in a function") end
			if #argv < start then
				local lines = {}
				for name in pairs(cmd == "export" and state.exported or state.locals[#state.locals]) do
					lines[#lines + 1] = cmd .. " " .. name .. "=" .. Builtins.quote(state.vars[name] or "")
				end
				table.sort(lines); return result(#lines > 0 and table.concat(lines, "\n") .. "\n" or "")
			end
			for at = start, #argv do
				local name, value = argv[at]:match("^([%a_][%w_]*)=(.*)$")
				name = name or argv[at]
				if not validName(name) then return errorResult(cmd .. ": invalid variable " .. name) end
				if cmd == "local" then
					local scope = state.locals[#state.locals]
					if scope[name] == nil then scope[name] = { state.vars[name], state.exported[name] } end
					-- `local X` DECLARES X unset for the function, it does not leave the
					-- caller's value showing. Without this `local count` read the outer
					-- count and a function that meant to start from nothing did not.
					state.vars[name] = nil
				else state.exported[name] = true end
				if value ~= nil then state.vars[name] = value end
			end
			return result()
		end
		if cmd == "unset" then
			local start, functions = 2, false
			if argv[start] == "-f" then functions = true; start += 1 elseif argv[start] == "-v" or argv[start] == "--" then start += 1 end
			for at = start, #argv do
				if not validName(argv[at]) then return errorResult("unset: invalid name " .. argv[at]) end
				if functions then state.functions[argv[at]] = nil else state.vars[argv[at]], state.exported[argv[at]] = nil, nil end
			end
			return result()
		end
		if cmd == "return" or cmd == "exit" then
			if cmd == "return" and #state.locals == 0 then return errorResult("return: only valid in a function") end
			local code = argv[2] and tonumber(argv[2]) or state.status
			if #argv > 2 or not code or code % 1 ~= 0 then return errorResult(cmd .. ": requires an integer status") end
			local r = result("", code % 256); r.flow = cmd; return r
		end
		if cmd == "break" or cmd == "continue" then
			local levels = argv[2] and tonumber(argv[2]) or 1
			if loopDepth == 0 then return errorResult(cmd .. ": only valid in a loop") end
			if #argv > 2 or not levels or levels < 1 or levels % 1 ~= 0 then return errorResult(cmd .. ": requires a positive loop count") end
			local r = result(); r.flow, r.levels = cmd, math.min(levels, loopDepth); return r
		end
		return nil
	end

	local function simple(node: any, stream: any): any
		local assignments, argv, first = {}, {}, 1
		context.captureStatus = nil
		while node.words[first] do
			local name, raw = node.words[first].raw:match("^([%a_][%w_]*)=(.*)$")
			if not name then break end
			assignments[#assignments + 1] = { name = name, raw = raw }; first += 1
		end
		for at = first, #node.words do
			-- export/local assignment operands do not undergo splitting or globbing.
			local assignment = (argv[1] == "export" or argv[1] == "local") and node.words[at].raw:match("^[%a_][%w_]*=")
			for _, value in ipairs(expand(node.words[at], assignment and "assignment" or nil)) do argv[#argv + 1] = value end
			if #argv > 10000 then error("command expansion exceeds 10000 arguments", 0) end
		end
		local saved = {}
		local ok, r = pcall(function()
			for _, assignment in ipairs(assignments) do
				if #argv > 0 and not SPECIAL[argv[1]] and saved[assignment.name] == nil then
					saved[assignment.name] = { state.vars[assignment.name] }
				end
				state.vars[assignment.name] = table.concat(Words.expand(assignment.raw, context, "assignment"))
			end
			if #argv == 0 then return result("", context.captureStatus or 0) end
			local bypass = false
			while argv[1] == "command" and argv[2] and argv[2]:sub(1, 1) ~= "-" do table.remove(argv, 1); bypass = true end
			local fn = not bypass and state.functions[argv[1]] or nil
			if fn then
				if depth + #state.locals > 32 then return errorResult("function call depth exceeds 32") end
				local oldArgs, scope = state.args, {}
				state.args = {}; table.move(argv, 2, #argv, 1, state.args)
				state.locals[#state.locals + 1] = scope
				local ran, answer = pcall(runNode, fn, stream)
				for name, old in pairs(scope) do state.vars[name], state.exported[name] = old[1], old[2] end
				table.remove(state.locals); state.args = oldArgs
				if not ran then error(answer, 0) end
				if answer.flow == "return" then answer.flow = nil end
				return answer
			end
			local handled = builtin(argv, stream)
			if handled then return handled end
			-- All argv entries are now data; even an expanded literal '>' must stay
			-- an argument when the legacy command dispatcher receives it.
			argv.quoted = {}; for at = 1, #argv do argv.quoted[at] = true end
			local stdin = stream.connected and stream.text:sub(stream.at) or nil
			local answer = api.command(terminal, argv, stdin, stream)
			if stdin ~= nil and api.consumes[argv[1]] then stream.at = #stream.text + 1 end
			-- ponytail: a handler returns its whole stdout and its whole stderr, so
			-- ONE command's two streams still concatenate rather than interleave.
			-- Ceiling: per-command ordering. Upgrade path is handlers writing chunks.
			local converted = result(answer.out, answer.code, answer.err)
			converted.prose, converted.preserveNewline = answer.prose, answer.preserveNewline
			return converted
		end)
		for name, old in pairs(saved) do state.vars[name] = old[1] end
		if not ok then error(r, 0) end
		return r
	end

	local function core(node: any, stream: any): any
		if node.kind == "simple" then return simple(node, stream) end
		if node.kind == "function" then state.functions[node.name] = node.body; return result() end
		if node.kind == "group" then return runList(node.body, stream) end
		if node.kind == "subshell" then return contained(execute(node.body, fork(terminal), api, budget, stream, depth + 1)) end
		if node.kind == "if" then
			local parts = {}
			for _, branch in ipairs(node.branches) do
				local condition = runList(branch.condition, stream)
				absorb(parts, condition, budget)
				-- The conditions already run are carried out with the flow. Returning
				-- the bare result dropped whatever they had printed on the way.
				if condition.flow then condition.parts = parts; return condition end
				if condition.code == 0 then
					local answer = runList(branch.body, stream)
					absorb(parts, answer, budget); answer.parts = parts
					return answer
				end
			end
			local answer = node.otherwise and runList(node.otherwise, stream) or result()
			absorb(parts, answer, budget); answer.parts = parts
			return answer
		end
		if node.kind == "case" then
			local value = table.concat(expand(node.word, "assignment"))
			for _, arm in ipairs(node.arms) do
				for _, pattern in ipairs(arm.patterns) do
					if Words.matches(table.concat(expand(pattern, "pattern")), value) then return runList(arm.body, stream) end
				end
			end
			return result()
		end
		local items = {}
		if node.kind == "for" then
			if node.items then for _, word in ipairs(node.items) do for _, value in ipairs(expand(word)) do items[#items + 1] = value end end
			else items = table.clone(state.args) end
		end
		local parts, answer, at = {}, result(), 1
		loopDepth += 1
		local ran, loopErr = pcall(function()
			while true do
				tick()
				if node.kind == "for" then
					if at > #items then break end
					state.vars[node.name] = items[at]; at += 1
				else
					local condition = runList(node.condition, stream)
					absorb(parts, condition, budget)
					if condition.flow then answer = condition; break end
					if (condition.code == 0) ~= (node.kind == "while") then break end
				end
				answer = runList(node.body, stream)
				absorb(parts, answer, budget)
				if answer.flow then
					if answer.flow == "break" or answer.flow == "continue" then
						answer.levels -= 1
						if answer.levels > 0 then break end
						local stop = answer.flow == "break"; answer.flow = nil
						if stop then break end
					else break end
				end
			end
		end)
		loopDepth -= 1
		if not ran then error(loopErr, 0) end
		answer.parts = parts
		return answer
	end

	function runNode(node: any, stream: any): any
		tick()
		-- Redirect targets are expanded and opened in order, before execution.
		-- Two redirects to the same descriptor still create/truncate both files.
		local descriptors = { [1] = { kind = "out" }, [2] = { kind = "err" } }
		local pendingAt = #context.diagnostics
		for _, redir in ipairs(node.redirects) do
			local op = redir.op
			local from, to = op:match("^(%d?)>&([%d%-])$")
			if to then
				local fd = tonumber(from) or 1
				descriptors[fd] = to == "-" and { kind = "null" } or descriptors[tonumber(to)]
				if not descriptors[fd] then return errorResult("unsupported file descriptor " .. to) end
			else
				local targets = redir.body ~= nil and { Syntax.literal(redir.word.raw) } or expand(redir.word)
				if #targets ~= 1 or targets[1] == "" then return errorResult("ambiguous redirect: " .. redir.word.raw) end
				local path = targets[1]
				if op:find("<<", 1, true) then
					local body = redir.body
					if redir.expand then
						body = table.concat(Words.expand(body, context, "heredoc"))
					end
					stream = { text = body, at = 1, connected = true, preserveNewline = true }
				elseif op:find("<", 1, true) then
					local body, err = api.read(terminal, path)
					if body == nil then return errorResult(err) end
					stream = { text = body, at = 1, connected = true, preserveNewline = true }
				else
					local target = { kind = path == "/dev/null" and "null" or "file", path = path }
					if target.kind == "file" then
						local err = api.write(terminal, path, "", op:find(">>", 1, true) ~= nil)
						if err then return errorResult(err) end
					end
					if op:sub(1, 1) == "&" then descriptors[1], descriptors[2] = target, target
					else descriptors[op:sub(1, 1) == "2" and 2 or 1] = target end
				end
			end
		end
		local r = core(node, stream)
		-- Anything a substitution wrote to stderr while this node's words were
		-- being expanded happened BEFORE the command ran, so it leads the output
		-- and is routed through this node's descriptors like any other chunk.
		if #context.diagnostics > pendingAt then
			local merged = {}
			for index = pendingAt + 1, #context.diagnostics do
				merged[#merged + 1] = { fd = 2, text = context.diagnostics[index] }
				context.diagnostics[index] = nil
			end
			table.move(r.parts, 1, #r.parts, #merged + 1, merged)
			r.parts = merged
		end
		-- Chunk by chunk in write order. A descriptor aimed at a file collects its
		-- text and is written once at the end, so `> f` is one append per file
		-- rather than one per chunk, and `&> f` keeps both streams interleaved.
		local routed, files, order = {}, {}, {}
		for _, part in ipairs(r.parts) do
			local target = descriptors[part.fd]
			if target.kind == "out" or target.kind == "err" then
				emit(routed, target.kind == "out" and 1 or 2, part.text, budget)
			elseif target.kind == "file" then
				if not files[target.path] then files[target.path] = {}; order[#order + 1] = target.path end
				table.insert(files[target.path], part.text)
			end
		end
		for _, path in ipairs(order) do
			local body = table.concat(files[path])
			if body ~= "" then
				local writeErr, note = api.write(terminal, path, body, true)
				if writeErr then emit(routed, 2, "bash: " .. writeErr .. "\n", budget); r.code = 2 end
				if note then emit(routed, 2, note .. "\n", budget) end
			end
		end
		r.parts = routed
		if descriptors[1].kind ~= "out" then r.prose = nil end
		state.status = r.code
		return r
	end

	function runList(list: any, stream: any): any
		local parts, last, lastProse = {}, result("", state.status), nil
		for _, statement in ipairs(list) do
			if statement.joiner == "&&" and last.code ~= 0 or statement.joiner == "||" and last.code == 0 then continue end
			if statement.joiner == "||" then lastProse = nil end
			if lastProse then emit(parts, 1, lastProse .. "\n", budget); lastProse = nil end
			local inputStream = stream
			for index, stage in ipairs(statement.stages) do
				if #statement.stages > 1 then
					local child = fork(terminal)
					last = contained(execute({ { joiner = ";", stages = { stage } } }, child, api, budget, inputStream, depth + 1))
				else last = runNode(stage, inputStream) end
				if index < #statement.stages then
					-- A stage's stdout goes down the pipe, not to the console. Its
					-- stderr goes to the console now, where bash puts it, rather than
					-- being held back until the last stage has finished.
					absorb(parts, last, budget, 2)
					last.prose = nil
				end
				inputStream = { text = text(last, 1), at = 1, connected = true, preserveNewline = last.preserveNewline }
			end
			if statement.negate then last.code = last.code == 0 and 1 or 0 end
			state.status = last.code
			absorb(parts, last, budget)
			lastProse = last.prose
			if last.flow then break end
		end
		last.parts, last.prose = parts, lastProse
		return last
	end
	return runList(ast, input)
end

function Runtime.run(terminal: any, line: string?, api: any): (string, number)
	terminal.shellState = terminal.shellState or initialState(terminal)
	local ok, ast = pcall(Syntax.parse, line or "")
	if not ok then terminal.shellState.status = 2; return "bash: " .. tostring(ast), 2 end
	local ran, answer = pcall(execute, ast, terminal, api, { steps = 10000, bytes = 0 },
		{ text = "", at = 1 }, 0)
	if not ran then terminal.shellState.status = 2; return "bash: " .. tostring(answer), 2 end
	terminal.shellState.status = answer.code
	local pieces = {}
	for _, part in ipairs(answer.parts) do pieces[#pieces + 1] = part.text end
	local output = table.concat(pieces)
	-- No newline is inserted between the streams: bash does not add one either,
	-- so `printf abc; cat missing` reports exactly what a terminal would show.
	if answer.prose then
		if output ~= "" and output:sub(-1) ~= "\n" then output ..= "\n" end
		output ..= answer.prose .. "\n"
	end
	-- Console messages are line-oriented. This is the only place a newline is
	-- removed; pipes, substitutions, groups and files above all carry real bytes.
	return answer.preserveNewline and text(answer, 2) == "" and output or (output:gsub("\n$", "")), answer.code
end

return Runtime
