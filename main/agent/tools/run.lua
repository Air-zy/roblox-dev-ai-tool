-- run: execute Luau in Studio.
--
-- Off unless the user opts in: arbitrary code at plugin permission level can do
-- anything the plugin can. The guard lives in Exec, next to the executor.
--
-- Path only. An inline `code` argument used to sit beside it, and the model kept
-- using it to rebuild this tool by hand off `.Source`, which is not the editor
-- buffer, so it tested stale text and reported a pass. See Exec.run.
return {
	name = "run",
	description = "runs luau, bound loops. scratch: /ServerStorage/tmp, NOT for vfs exploration/edits",
	input_schema = {
		type = "object",
		properties = {
			path = { type = "string" },
		},
		required = { "path" },
	},
	run = function(term: any, input: { [string]: any }): string
		local s, err = term:run(input.path)
		return s or ("run: " .. tostring(err))
	end,
}
