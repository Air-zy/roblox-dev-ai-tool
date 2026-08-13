-- bash: the whole shell, as one tool.
--
-- The description carries the MAPPING and stops. `ls`, `grep` and `cp` describe
-- themselves; what a model cannot guess is that this filesystem is a DataModel.
-- Everything else that would go here lives in an error message instead, where it
-- costs nothing until a call actually needs it.
return {
	name = "bash",
	description = "default to bash for data model exploration/edits",
	input_schema = {
		type = "object",
		properties = { command = { type = "string" } },
		required = { "command" },
	},
	run = function(term: any, input: { [string]: any }): string
		return term:shell(input.command)
	end,
}
