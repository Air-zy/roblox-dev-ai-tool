-- agent: hand a task to a subagent, a second run of the tool loop with its own
-- history. Only its final message comes back, so its searching and reading never
-- enter the caller's context. The loop itself is Agent.runChild.
--
-- Required at call time, not at the top: Agent requires Tools, which requires
-- this file, so a top-level require of Agent would be a recursive one.

-- How many of the provider's models the schema names. The rest still work by id.
-- ponytail: first 12 in picker order; rank them if a long roster hides the useful ones.
local LISTED_MODELS = 12

return {
	name = "agent",
	description = "copy of you, same tools, none of this conversation unless fork; returns only its final message. "
		.. "for broad searches and independent subtasks; calls in one message run in parallel",
	-- A function, read per request: the model ids are whichever provider is on now.
	input_schema = function(): any
		local Provider = require(script.Parent.Parent:WaitForChild("Provider")) :: any
		local models: { string } = {}
		for _, entry in ipairs(Provider.wire and Provider.wire.MODELS or {}) do
			if #models == LISTED_MODELS then
				models[#models + 1] = "…"
				break
			end
			models[#models + 1] = if entry.hint then entry.id .. " (" .. entry.hint .. ")" else entry.id
		end
		return {
			type = "object",
			properties = {
				description = { type = "string", description = "3-5 word label" },
				prompt = { type = "string", description = "the whole task; without fork it knows nothing else" },
				model = { type = "string", description = "omit for yours"
					.. (if #models > 0 then "; " .. table.concat(models, ", ") else "") },
				fork = { type = "boolean", description = "start from a copy of this conversation; keeps your model" },
				run_in_background = { type = "boolean",
					description = "return at once; its report arrives later as a <task-notification>, so do not wait or poll" },
			},
			required = { "description", "prompt" },
		}
	end,
	run = function(term: any, input: { [string]: any }): string
		return require(script.Parent.Parent:WaitForChild("Agent")).runChild(term, input)
	end,
}
