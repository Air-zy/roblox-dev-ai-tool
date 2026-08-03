-- run — execute Luau in Studio.
--
-- Off unless the user opts in: arbitrary code at plugin permission level can do
-- anything the plugin can. The guard lives in Terminal, next to the executor.
return {
	name = "run",
	description = "only use if bash cant, executes luau source, no timeout",
	input_schema = {
		type = "object",
		properties = { code = { type = "string" } },
		required = { "code" },
	},
	run = function(term: any, input: { [string]: any }): string
		local s, err = term:run(input.code)
		return s or ("run: " .. tostring(err))
	end,
}
