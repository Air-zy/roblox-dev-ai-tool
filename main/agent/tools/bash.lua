-- bash: the whole shell, as one tool.
--
-- The description carries the MAPPING and stops. `ls`, `grep` and `cp` describe
-- themselves; what a model cannot guess is that this filesystem is not one.
--
-- "live in-memory vfs" rather than the name of what it really is, for two
-- reasons. It is the half that changes behaviour — naming the class only helps a
-- reader who already knows it, and this tool should not need that reader. And it
-- is the half that kills the wrong guess: dropping the phrase entirely had models
-- settling on Rojo, the obvious way to reconcile "bash" with "Studio", and naming
-- the DataModel does not rule Rojo out at all — projecting files into one is
-- exactly what Rojo does. "In-memory" does. A model that wants to know what the
-- objects are gets it from `ls /`, pulled, not pushed.
--
-- "with network" is there to undo what that same clause costs. "In-memory vfs"
-- can suggest an isolated sandbox, and that reading takes curl,
-- wget and git off the table before any of them is tried. The failure is silent —
-- a model that has concluded there is no network never calls one and never sees
-- a refusal — so it is the one capability worth stating rather than leaving to
-- `help`, which only answers a question that gets asked.
--
-- Everything else that would go here lives in an error message instead, where it
-- costs nothing until a call actually needs it. `help` covers what used to be
-- "and more": the command list is derived, so it cannot go stale here.
return {
	name = "bash",
	description = "real bash shell over a live in-memory vfs, with network",
	input_schema = {
		type = "object",
		properties = { command = { type = "string" } },
		required = { "command" },
	},
	run = function(term: any, input: { [string]: any }): string
		return term:shell(input.command)
	end,
}
