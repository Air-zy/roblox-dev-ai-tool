--!strict
-- Tools.luau — the tool registry.
--
-- Every ModuleScript under `tools/` exports either one tool or an array of them:
--   { name, description, input_schema, run(term, input) -> string }
-- Adding a tool is adding a file. Nothing else in the codebase has to change —
-- which is the entire reason this module exists, since the old shape needed an
-- entry in a literal array plus a branch in an if/else chain, in the same 2500
-- line file that also held the filesystem and the shell.

export type Tool = {
	name: string,
	description: string,
	input_schema: any,
	run: (any, { [string]: any }) -> string,
}

local Tools = {}

local defs: { Tool } = {}
local byName: { [string]: Tool } = {}

-- Sorted by module name, then by declaration order within a module.
--
-- The sort is NOT tidiness. Tool definitions render at the very front of the
-- request, ahead of the system prompt and the conversation, and prompt caching
-- is a prefix match — reorder two tools and every cache_control breakpoint after
-- them misses, for the whole session. GetChildren() returns no guaranteed order,
-- so without this the tool block could serialise differently between two Studio
-- launches and quietly halve the cache hit rate.
local folder = script.Parent:WaitForChild("tools")
local modules = folder:GetChildren()
table.sort(modules, function(a, b)
	return a.Name < b.Name
end)

for _, module in ipairs(modules) do
	if module:IsA("ModuleScript") then
		local exported = require(module) :: any
		-- One tool, or several: a module exporting a single tool has a `name`,
		-- an array does not.
		local entries: { Tool } = type(exported.name) == "string" and { exported } or exported
		for _, tool in ipairs(entries) do
			assert(type(tool.name) == "string" and tool.name ~= "",
				module.Name .. ": tool is missing a name")
			assert(type(tool.run) == "function",
				tool.name .. ": tool is missing a run function")
			assert(not byName[tool.name],
				"duplicate tool name: " .. tool.name)
			defs[#defs + 1] = tool
			byName[tool.name] = tool
		end
	end
end

-- The API-shaped definitions, in stable order. Agent copies this before tagging
-- a cache breakpoint onto the last entry.
function Tools.definitions(): { any }
	local out: { any } = {}
	for i, tool in ipairs(defs) do
		out[i] = {
			name = tool.name,
			description = tool.description,
			input_schema = tool.input_schema,
		}
	end
	return out
end

function Tools.has(name: string): boolean
	return byName[name] ~= nil
end

function Tools.names(): { string }
	local out: { string } = {}
	for i, tool in ipairs(defs) do
		out[i] = tool.name
	end
	return out
end

-- Runs a tool. Never throws: a tool that errors returns the error as its result,
-- because every tool_use needs a matching tool_result and an unanswered one is a
-- protocol error that poisons the rest of the conversation.
function Tools.dispatch(term: any, name: string, input: { [string]: any }): string
	local tool = byName[name]
	if not tool then
		return "error: unknown tool '" .. tostring(name) .. "'"
	end
	local ok, result = pcall(tool.run, term, input)
	if not ok then
		return string.format("%s: threw: %s", name, tostring(result))
	end
	return result
end

return Tools
