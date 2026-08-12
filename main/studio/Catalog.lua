--!strict
--!optimize 2
-- Roblox Free Model search and insert. Reached only through the `catalog`
-- tool; no shell command touches it.
local Fs = require(script.Parent.Parent:WaitForChild("fs"):WaitForChild("Fs"))
local instancePath = Fs.instancePath
local withUndo     = Fs.withUndo

local Catalog = {}

-- GetFreeModelsAsync returns a plain table, not CatalogPages:
--   { [1] = { CurrentStartIndex, TotalCount, Results = { {Name, AssetId, ...} } } }
--
-- Those rows say nothing about whether an asset can be inserted, and the search
-- backend is not the Toolbox ranker, so it returns keyword spam. One
-- GetProductInfo per result fixes both: IsPublicDomain and AssetTypeId drop what
-- is not a free-to-take Model, Sales sinks the spam. Issued in parallel, so the
-- search pays one yield rather than twenty-one. It narrows the list; it does not
-- promise a load will succeed.
--
-- Load uses GetObjects, not LoadAsset or LoadAssetAsync. Both of those gate on
-- ownership, and the switch that lifts it (AllowInsertFreeAssets) is
-- RobloxScriptSecurity, so a plugin can neither read nor set it. GetObjects is
-- PluginSecurity and predates the check, which makes it the only route we have.
--
-- Tradeoff, taken knowingly: GetObjects does not sandbox, so scripts inside a
-- model arrive live and able to run. Free models are the classic backdoor
-- vector, so a load reports how many scripts came with it. Auto-disabling them
-- was rejected, it breaks every model whose scripts are the point of it.
-- GetObjects is also deprecated and does not yield, so it blocks Studio for the
-- fetch. Move back to the sandboxed path if either limitation ever lifts.
--
-- No pageNum: pages 3 and up come back empty whatever the query, and a knob that
-- does nothing costs the model a turn to discover. Search loads nothing either,
-- the model picks an id and loads that one explicitly.
local InsertService = game:GetService("InsertService")
local MarketplaceService = game:GetService("MarketplaceService")

-- A single page returns up to ~21 entries per the Roblox docs. The cap exists
-- because one unbounded search is enough to evict the rest of the conversation
-- from context, the same reason MAX_CAT_LINES exists.
local MAX_CATALOG_RESULTS = 20
-- Enum.AssetType.Model, compared as a number because GetProductInfo returns the
-- raw id rather than the enum.
local ASSET_TYPE_MODEL = 10
-- One slow GetProductInfo must not hang the whole tool call. Whatever has not
-- answered by then is dropped, which costs a result, not the search.
local PRODUCT_INFO_TIMEOUT = 15

-- GetProductInfo yields, so twenty serial calls cost twenty round-trips end to
-- end. Spawned, they overlap and the caller waits only for the slowest. Indexes
-- line up with `ids` so the result can be zipped back against the search rows;
-- a call that errors or times out simply leaves a hole, and a model we cannot
-- describe is a model we should not offer.
--
-- ponytail: polls with task.wait and re-fetches every search; swap the busy-wait
-- for a counting signal and memoise by assetId if searches ever get chatty.
local function productInfoBatch(ids: { number }): { [number]: any }
	local out: { [number]: any } = {}
	local pending = #ids
	for i, id in ipairs(ids) do
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset)
			end)
			if ok and type(info) == "table" then
				out[i] = info
			end
			pending -= 1
		end)
	end
	local deadline = os.clock() + PRODUCT_INFO_TIMEOUT
	while pending > 0 and os.clock() < deadline do
		task.wait()
	end
	return out
end

type FreeModel = { id: number, name: string, creator: string, sales: number }

-- Drop what will not load, order what remains. Pure and split out from
-- catalogSearch precisely so selfTest can exercise it without the network
-- this function is what decides which ids the model is allowed to see, and a
-- regression either leaks unloadable ids or drops everything, both of which
-- look like "the catalog is down" from the outside.
local function rankFreeModels(results: { any }, infos: { [number]: any }): { FreeModel }
	local kept: { FreeModel } = {}
	for i, entry in ipairs(results) do
		local info = infos[i]
		-- AssetId comes back as a number per the docs; some entries have been
		-- seen to return string ids, so tonumber covers both.
		local id = type(entry) == "table" and tonumber(entry.AssetId) or nil
		if id and type(info) == "table" and info.IsPublicDomain == true
			and tonumber(info.AssetTypeId) == ASSET_TYPE_MODEL then
			local creator = entry.CreatorName
			if (creator == nil or creator == "") and type(info.Creator) == "table" then
				creator = info.Creator.Name
			end
			table.insert(kept, {
				id = id,
				name = tostring(info.Name or entry.Name or "(unnamed)"),
				creator = tostring(creator or ""),
				sales = tonumber(info.Sales) or 0,
			})
		end
	end
	-- Sales is the take count for a free model, and the only popularity signal
	-- GetProductInfo carries, there is no favourites field. Ties break on id
	-- because table.sort is not stable, and an order that shuffles between two
	-- identical searches reads as a changed result set.
	table.sort(kept, function(a, b)
		if a.sales ~= b.sales then
			return a.sales > b.sales
		end
		return a.id < b.id
	end)
	return kept
end

function Catalog.search(self: any, query: string?): (string?, string?)
	if not query or query == "" then
		return nil, "catalog search requires a query"
	end

	-- Return type is a plain Lua table, NOT a CatalogPages Instance, the
	-- docs describe it as "a single table wrapped in a table":
	--   { [1] = { CurrentStartIndex, TotalCount, Results = { {Name, AssetId,
	--            AssetVersionId, CreatorName}, ... } } }
	-- So unpack the outer wrapper to reach the page object, then read .Results.
	-- pageNum is required and 0-indexed; 0 is the only page worth asking for.
	local raw: any
	local ok, err = pcall(function()
		raw = InsertService:GetFreeModelsAsync(query :: string, 0)
	end)
	if not ok then
		return nil, "GetFreeModelsAsync failed: " .. tostring(err)
	end
	if typeof(raw) ~= "table" then
		return nil, "GetFreeModelsAsync returned " .. typeof(raw) ..
			", expected a table (per docs: a table wrapped in a table)"
	end

	-- Unwrap: docs show the outer table has a single entry at [1] holding the
	-- page object. Be defensive, if the shape ever changes, surface it rather
	-- than silently returning "no models".
	local pageObj = raw[1]
	if type(pageObj) ~= "table" then
		return nil, "GetFreeModelsAsync returned an unexpected shape: outer " ..
			"table has no [1] entry of type table (got " .. type(pageObj) .. ")"
	end

	local results = pageObj.Results
	if type(results) ~= "table" or #results == 0 then
		return "no models found for " .. query, nil
	end

	-- Keep the index alignment even for malformed rows: rankFreeModels zips
	-- `infos[i]` against `results[i]`, so a skipped row would shift every id
	-- after it onto the wrong product info. A 0 here fails GetProductInfo,
	-- leaves a hole, and the row is dropped, which is the right answer anyway.
	local ids: { number } = {}
	for i, entry in ipairs(results) do
		ids[i] = (type(entry) == "table" and tonumber(entry.AssetId)) or 0
	end

	local kept = rankFreeModels(results, productInfoBatch(ids))
	if #kept == 0 then
		return string.format(
			"no loadable free models for %s — %d result(s) came back, none of them public-domain models",
			query, #results), nil
	end

	local shown = math.min(#kept, MAX_CATALOG_RESULTS)
	local lines: { string } = {}
	for i = 1, shown do
		local m = kept[i]
		-- Description is deliberately omitted even though GetProductInfo now
		-- carries it: free-model descriptions run to paragraphs of SEO, and
		-- twenty of them would cost more context than the search is worth.
		local creator = m.creator ~= "" and ("  by " .. m.creator) or ""
		table.insert(lines, string.format("%d. %s  [id %d]%s  (%d takes)",
			i, m.name, m.id, creator, m.sales))
	end

	local trailer = ""
	if #kept > shown then
		trailer = string.format("\n… %d more loadable results — refine the query",
			#kept - shown)
	end
	return table.concat(lines, "\n") .. trailer, nil
end

function Catalog.load(self: any, assetId: number?, parentPath: string?): (string?, string?)
	if not assetId or assetId <= 0 then
		return nil, "catalog load requires a positive assetId"
	end

	local parent: Instance?
	if parentPath and parentPath ~= "" then
		local resolved, err = self:resolve(parentPath)
		if not resolved then
			return nil, "parent: " .. tostring(err)
		end
		parent = resolved
	else
		parent = game:GetService("Workspace")
	end

	local asset: Instance?
	local scriptCount = 0
	local _, loadErr = withUndo("Claude: load asset " .. tostring(assetId), function()
		-- GetObjects returns an ARRAY of roots, not one Instance: an asset is a
		-- list of top-level objects, and a Model is merely the common case of a
		-- list with one entry.
		local roots = game:GetObjects("rbxassetid://" .. tostring(assetId))
		if type(roots) ~= "table" or #roots == 0 then
			error("GetObjects returned nothing for asset " .. tostring(assetId), 2)
		end

		local a: Instance
		if #roots == 1 then
			-- One root is the overwhelmingly common shape. Use it directly so the
			-- result looks exactly like what the Toolbox would have inserted,
			-- rather than burying it under a wrapper nothing asked for.
			a = roots[1]
		else
			-- Several roots have to go somewhere, and returning them loose would
			-- scatter them across the parent with no way to undo-by-name or refer
			-- to the asset as one thing. A Folder is the cheapest container that
			-- adds no behaviour of its own.
			a = Instance.new("Folder")
			for _, r in ipairs(roots) do
				r.Parent = a
			end
		end

		-- Rename to Asset_<id> so the result is findable by name in the next
		-- breath, and so two loads of the same asset sit next to each other
		-- instead of colliding on the asset's own (often generic) name.
		a.Name = "Asset_" .. tostring(assetId)
		a.Parent = parent
		asset = a

		-- Count what came in. GetObjects does NOT sandbox (see the header note),
		-- so scripts arrive live and enabled, the caller is owed the number
		-- before it decides to run anything. Reporting beats auto-disabling:
		-- disabling would quietly break every model whose scripts are the point.
		for _, d in ipairs(a:GetDescendants()) do
			if d:IsA("LuaSourceContainer") then
				scriptCount += 1
			end
		end
	end)
	if loadErr then
		-- GetObjects bypasses the ownership checks entirely, so the "not trusted"
		-- / "not authorized" refusals that LoadAsset raised cannot occur here.
		-- What is left is a genuinely bad id: missing, moderated, or not an asset
		-- this account may fetch at all.
		local msg = tostring(loadErr)
		return nil, "GetObjects: " .. msg ..
			" — asset " .. tostring(assetId) ..
			" does not exist, has been moderated, or is not a model asset."
	end

	local a = asset :: Instance
	local scripts = ""
	if scriptCount > 0 then
		scripts = string.format(", %d script%s — NOT sandboxed, inspect before running",
			scriptCount, scriptCount == 1 and "" or "s")
	end
	return string.format("loaded asset %d as %s (%d children, %d descendants%s)",
		assetId, instancePath(a), #a:GetChildren(), #a:GetDescendants(), scripts), nil
end


function Catalog.selfTest(): (boolean, string?)
	-- rankFreeModels is the only catalog logic that runs without the network,
	-- and it is the gate deciding which ids the model may see. Broken one way it
	-- offers assets that fail at load; broken the other it returns nothing and
	-- looks like an outage. Row 5 has no product info at all, the timeout case.
	local ranked = rankFreeModels({
		{ AssetId = 1, Name = "spam",    CreatorName = "a" },
		{ AssetId = 2, Name = "good",    CreatorName = "b" },
		{ AssetId = 3, Name = "private", CreatorName = "c" },
		{ AssetId = 4, Name = "decal",   CreatorName = "d" },
		{ AssetId = 5, Name = "timeout", CreatorName = "e" },
	}, {
		[1] = { IsPublicDomain = true,  AssetTypeId = 10, Sales = 3 },
		[2] = { IsPublicDomain = true,  AssetTypeId = 10, Sales = 99 },
		[3] = { IsPublicDomain = false, AssetTypeId = 10, Sales = 500 },
		[4] = { IsPublicDomain = true,  AssetTypeId = 13, Sales = 500 },
	})
	if #ranked ~= 2 then
		return false, string.format(
			"rankFreeModels kept %d of 5 (expected 2: private, non-Model and info-less rows must all drop)",
			#ranked)
	end
	if ranked[1].id ~= 2 or ranked[2].id ~= 1 then
		return false, string.format("rankFreeModels ordered %d,%d — expected 2,1 (sales descending)",
			ranked[1].id, ranked[2].id)
	end

	return true
end

return Catalog
