-- write: replace a script's entire source.
return {
	name = "write",
	description = "set entire source, creates the script if missing, use cp/mv or pipe curl instead of rewriting",
	input_schema = {
		type = "object",
		properties = {
			path = { type = "string" },
			content = { type = "string" },
		},
		required = { "path", "content" },
	},
	run = function(term: any, input: { [string]: any }): string
		local s, err = term:write(input.path, input.content)
		return s or ("write: " .. tostring(err))
	end,
}
