-- catalog — search Roblox Free Models, load one by id.
--
-- Search touches nothing and returns TEXT only; load inserts exactly ONE Model
-- under a parent the caller names. Nothing is loaded on search because the
-- catalog returns dozens of plausible results per query and inserting each would
-- fill Workspace with instances the caller never inspected.
--
-- No pageNum: the underlying API returns nothing past page 2, so the parameter
-- only ever bought the model a wasted turn. Results are filtered to public-domain
-- Models and sorted by take count — see the catalog section of Terminal.
return {
	name = "catalog",
	description = "search Roblox Free Models; load one by id",
	input_schema = {
		type = "object",
		properties = {
			action = { type = "string", enum = { "search", "load" } },
			query = { type = "string" },
			assetId = { type = "number" },
			parent = { type = "string" },
		},
		required = { "action" },
	},
	run = function(term: any, input: { [string]: any }): string
		local action = input.action
		if action == "search" then
			local s, err = term:catalogSearch(input.query)
			return s or ("catalog: " .. tostring(err))
		elseif action == "load" then
			local s, err = term:catalogLoad(input.assetId, input.parent)
			return s or ("catalog: " .. tostring(err))
		end
		return string.format("catalog: unknown action: %s — expected \"search\" or \"load\"",
			tostring(action))
	end,
}
