-- run: execute Luau in Studio.
--
-- Off unless the user opts in: arbitrary code at plugin permission level can do
-- anything the plugin can. The guard lives in Terminal, next to the executor.
--
-- `path` exists so a chunk worth running twice is written once and iterated with
-- `edit`, instead of resent whole every time. The description says where scratch
-- scripts live because nothing else can tell the model that; it does NOT explain
-- why, and it does not carry the `script`-is-the-runner caveat. Both of those
-- are in the README, and the code/path exclusivity is already an error message.
return {
	name = "run",
	description = "only use if bash cant, executes luau source, no timeout. " ..
		"code, or path to a script holding it; scratch scripts go in /ServerStorage/tmp",
	input_schema = {
		type = "object",
		properties = {
			code = { type = "string" },
			path = { type = "string" },
		},
	},
	run = function(term: any, input: { [string]: any }): string
		local s, err = term:run(input.code, input.path)
		return s or ("run: " .. tostring(err))
	end,
}
