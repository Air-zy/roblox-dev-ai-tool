-- edit / multiedit, substring replacement in a script.
--
-- Structured arguments rather than a shell line because the payload is Luau
-- source: routing that through shell quoting would eventually corrupt someone's
-- script, and JSON parameters already solve escaping.
return {
	{
		name = "edit",
		description = "replace one unique occurrence of old_string in script.",
		input_schema = {
			type = "object",
			properties = {
				path = { type = "string" },
				old_string = { type = "string" },
				new_string = { type = "string" },
			},
			required = { "path", "old_string", "new_string" },
		},
		run = function(term: any, input: { [string]: any }): string
			local s, err = term:edit(input.path, input.old_string, input.new_string)
			return s or ("edit: " .. tostring(err))
		end,
	},
	{
		name = "multiedit",
		description = "multiple edits to one script",
		input_schema = {
			type = "object",
			properties = {
				path = { type = "string" },
				edits = {
					type = "array",
					items = {
						type = "object",
						properties = {
							old_string = { type = "string" },
							new_string = { type = "string" },
						},
						required = { "old_string", "new_string" },
					},
				},
			},
			required = { "path", "edits" },
		},
		run = function(term: any, input: { [string]: any }): string
			local s, err = term:multiedit(input.path, input.edits)
			return s or ("multiedit: " .. tostring(err))
		end,
	},
}
