-- agent: hand a task to a subagent, a second run of the tool loop with its own
-- history. Only its final message comes back, so its searching and reading never
-- enter the caller's context. The loop itself is Agent.runChild.
--
-- Required at call time, not at the top: Agent requires Tools, which requires
-- this file, so a top-level require of Agent would be a recursive one.
return {
	name = "agent",
	description = "fresh copy of you, same tools, none of this conversation; returns only its final message. "
		.. "for broad searches and independent subtasks; calls in one message run in parallel",
	input_schema = {
		type = "object",
		properties = {
			description = { type = "string", description = "3-5 word label" },
			prompt = { type = "string", description = "the whole task, it knows nothing else" },
		},
		required = { "description", "prompt" },
	},
	run = function(term: any, input: { [string]: any }): string
		return require(script.Parent.Parent:WaitForChild("Agent")).runChild(term, input)
	end,
}
