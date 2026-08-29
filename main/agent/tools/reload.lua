-- reload: uncache edited modules. Runs nothing itself — it makes the NEXT
-- require of these paths load the current source instead of the first one.
--
-- Its own tool rather than a shell command because there is no `reload` in bash
-- to borrow the spelling from, and this is the thing a test script needs after
-- every edit: the shell's commands are ones a model already knows.
return {
	name = "reload",
	description = "uncache modules so the next require reads the current source. list dependents too",
	input_schema = {
		type = "object",
		properties = {
			paths = { type = "array", items = { type = "string" } },
		},
		required = { "paths" },
	},
	run = function(term: any, input: { [string]: any }): string
		local s, err = term:reload(input.paths)
		return s or ("reload: " .. tostring(err))
	end,
}
