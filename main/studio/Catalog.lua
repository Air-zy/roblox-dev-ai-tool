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
-- GetProductInfoAsync per result fixes both: IsPublicDomain and AssetTypeId drop what
-- is not a free-to-take Model. Issued in parallel, so the search pays one yield
-- rather than twenty-one. It narrows the list; it does not promise a load will
-- succeed. Note (June 2026): GetProductInfoAsync was hit with a severe silent rate
-- limit reduction. The existing pcall + 15s timeout degrades gracefully (429 -> hole
-- -> dropped row), at the cost of fewer kept results per search.
--
-- Load uses GetObjects, not LoadAsset or LoadAssetAsync. LoadAsset historically gated
-- on ownership. As of Aug 2025, Roblox extended LoadAsset to support models shared
-- with the experience, and is investigating allowing insertion of any public free
-- model. Until that ships, GetObjects (PluginSecurity, deprecated) is the only route
-- we have that bypasses the ownership check for arbitrary catalog free models.
--
-- Tradeoff, taken knowingly: GetObjects does not sandbox, so scripts inside a
-- model arrive live and able to run. Free models are the classic backdoor
-- vector, so a load reports how many scripts came with it. Auto-disabling them
-- was rejected, it breaks every model whose scripts are the point of it.
-- GetObjects also does not participate in the Aug 2025 dependency auto-granting
-- flow that LoadAsset got, so a free model referencing Restricted sub-assets
-- (Meshes/Decals) may insert with broken/missing references.
--
-- No pageNum: pages 3 and up come back empty whatever the query, and a knob that
-- does nothing costs the model a turn to discover. Search loads nothing either,
-- the model picks an id and loads that one explicitly.
local InsertService = game:GetService("InsertService")
local MarketplaceService = game:GetService("MarketplaceService")

local MAX_CATALOG_RESULTS = 10
local ASSET_TYPE_MODEL = Enum.AssetType.Model.Value
local PRODUCT_INFO_TIMEOUT = 15

-- GetProductInfoAsync yields, so twenty serial calls cost twenty round-trips end to
-- end. Spawned, they overlap and the caller waits only for the slowest. Indexes
-- line up with `ids` so the result can be zipped back against the search rows;
-- a call that errors, times out, or hits a 429 rate limit simply leaves a hole,
-- and a model we cannot describe is a model we should not offer.
local function productInfoBatch(ids: { number }): { [number]: any }
	local out: { [number]: any } = {}
	local pending = #ids
	for i, id in ipairs(ids) do
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfoAsync(id, Enum.InfoType.Asset)
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

type FreeModel = { id: number, name: string, creator: string, score: number }

-- Extracts lowercase alphanumeric words from a string.
local function tokenize(str: string): { [string]: boolean }
	local tokens = {}
	for word in string.gmatch(string.lower(str), "%w+") do
		tokens[word] = true
	end
	return tokens
end

-- Calculate a deterministic relevance score (0.0 to 1.0).
-- We use Token F1 Score (harmonic mean of Coverage and Purity) combined with 
-- continuous substring bonuses. This allows partial word overlaps to be scored
-- fairly rather than relying on rigid exact/prefix tiers.
-- We also add a massive bonus (+500) if the creator has the Verified badge, as 
-- verified creators are significantly less likely to upload SEO spam/backdoors.
local function calculateScore(query: string, name: string, index: number, isVerified: boolean): number
	local lQuery = string.lower(query)
	local lName = string.lower(name)

	local qTokens = tokenize(lQuery)
	local nTokens = tokenize(lName)

	local qCount = 0
	local nCount = 0
	local intersect = 0

	for _ in pairs(qTokens) do qCount += 1 end
	for _ in pairs(nTokens) do nCount += 1 end

	if qCount == 0 or nCount == 0 then
		return 0.0
	end

	for token in pairs(qTokens) do
		if nTokens[token] then
			intersect += 1
		end
	end

	-- Token F1 Score
	local coverage = intersect / qCount -- How much of the query is in the name?
	local purity = intersect / nCount   -- How much of the name is the query? (Penalizes SEO spam)
	local tokenScore = 0.0
	if intersect > 0 then
		tokenScore = 2 * (coverage * purity) / (coverage + purity)
	end

	local similarity = tokenScore

	-- Continuous substring bonuses (capped at 1.0)
	if lName == lQuery then
		similarity = 1.0
	elseif string.sub(lName, 1, #lQuery) == lQuery then
		similarity = math.max(similarity, 0.9) -- Prefix match
	elseif string.find(lName, lQuery, 1, true) then
		similarity = math.max(similarity, 0.8) -- Substring match
	end

	-- Scale similarity to 1000 points. A 10% similarity difference (100 pts) 
	-- will outweigh any search index difference.
	local rankWeight = 100 - math.min((index - 1) * 5, 100)
	local baseScore = (similarity * 1000) + rankWeight

	if isVerified then
		baseScore += 500 -- Authenticity boost
	end

	return baseScore
end

-- Drop what will not load, order what remains. Pure and split out from
-- catalogSearch precisely so selfTest can exercise it without the network.
-- This function is what decides which ids the model is allowed to see, and a
-- regression either leaks unloadable ids or drops everything, both of which
-- look like "the catalog is down" from the outside.
local function filterFreeModels(query: string, results: { any }, infos: { [number]: any }): { FreeModel }
	local kept: { FreeModel } = {}
	for i, entry in ipairs(results) do
		local info = infos[i]
		local id = type(entry) == "table" and tonumber(entry.AssetId) or nil
		if id and type(info) == "table" and info.IsPublicDomain == true
			and tonumber(info.AssetTypeId) == ASSET_TYPE_MODEL then

			local name = tostring(info.Name or entry.Name or "(unnamed)")
			local creator = entry.CreatorName
			local isVerified = false

			if type(info.Creator) == "table" then
				if creator == nil or creator == "" then
					creator = info.Creator.Name
				end
				-- Check for the verified badge in the Creator sub-table
				if info.Creator.HasVerifiedBadge == true then
					isVerified = true
				end
			end

			table.insert(kept, {
				id = id,
				name = name,
				creator = tostring(creator or ""),
				score = calculateScore(query, name, i, isVerified),
			})
		end
	end
	table.sort(kept, function(a, b)
		return a.score > b.score
	end)
	return kept
end

function Catalog.search(self: any, query: string?): (string?, string?)
	if not query or query == "" then
		return nil, "catalog search requires a query"
	end

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

	local pageObj = raw[1]
	if type(pageObj) ~= "table" then
		return nil, "GetFreeModelsAsync returned an unexpected shape: outer " ..
			"table has no [1] entry of type table (got " .. type(pageObj) .. ")"
	end

	local results = pageObj.Results
	if type(results) ~= "table" or #results == 0 then
		return "no models found for " .. query, nil
	end

	-- Keep the index alignment even for malformed rows: filterFreeModels zips
	-- `infos[i]` against `results[i]`, so a skipped row would shift every id
	-- after it onto the wrong product info. A 0 here fails GetProductInfoAsync,
	-- leaves a hole, and the row is dropped, which is the right answer anyway.
	local ids: { number } = {}
	for i, entry in ipairs(results) do
		ids[i] = (type(entry) == "table" and tonumber(entry.AssetId)) or 0
	end

	local kept = filterFreeModels(query :: string, results, productInfoBatch(ids))
	if #kept == 0 then
		return string.format(
			"no loadable free models for %s - %d result(s) came back, none of them public-domain models",
			query, #results), nil
	end

	local shown = math.min(#kept, MAX_CATALOG_RESULTS)
	local lines: { string } = {}
	for i = 1, shown do
		local m = kept[i]
		local creator = m.creator ~= "" and ("  by " .. m.creator) or ""
		table.insert(lines, string.format("%d. %s  [id %d]%s",
			i, m.name, m.id, creator))
	end

	local trailer = "\nload and look through each and manually filter for the best quality"
	if #kept > shown then
		trailer ..= string.format("\n… %d more loadable results - refine the query",
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
	local partCount = 0
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

		-- Check the root itself in case it's a single Part or Script
		if a:IsA("LuaSourceContainer") then
			scriptCount += 1
		elseif a:IsA("BasePart") then
			partCount += 1
		end

		for _, d in ipairs(a:GetDescendants()) do
			if d:IsA("LuaSourceContainer") then
				scriptCount += 1
			elseif d:IsA("BasePart") then
				partCount += 1
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
			" - asset " .. tostring(assetId) ..
			" does not exist, has been moderated, or is not a model asset."
	end

	local a = asset :: Instance
	local details: { string } = {}

	-- Report the root class so the caller knows if they got a Model, Tool, or Part
	table.insert(details, "root " .. a.ClassName)

	-- Infer physical scale if the root is a Model
	if a:IsA("Model") then
		local _, size = a:GetBoundingBox()
		if size.Magnitude > 0 then
			table.insert(details, string.format("scale %dx%dx%d studs", 
				math.round(size.X), math.round(size.Y), math.round(size.Z)))
		end
	end

	-- Report geometry
	table.insert(details, string.format("%d part%s", partCount, partCount == 1 and "" or "s"))

	-- Report scripts with the safety warning
	if scriptCount > 0 then
		table.insert(details, string.format("%d script%s inside",
			scriptCount, scriptCount == 1 and "" or "s"))
	end

	return string.format("loaded asset %d as %s (%s)",
		assetId, instancePath(a), table.concat(details, ", ")), nil
end

function Catalog.selfTest(): (boolean, string?)
	-- filterFreeModels is the only catalog logic that runs without the network,
	-- and it is the gate deciding which ids the model may see. Broken one way it
	-- offers assets that fail at load; broken the other it returns nothing and
	-- looks like an outage. 
	-- Note: infos[i] must align with results[i]'s array index, NOT its AssetId.
	local query = "red sword"
	local results = {
		{ AssetId = 1, Name = "red sword",         CreatorName = "a" }, -- 1: Exact (Unverified) -> 1000 + 95 = 1095
		{ AssetId = 2, Name = "red sword v2",       CreatorName = "b" }, -- 2: Prefix (Verified) -> 900 + 90 + 500 = 1490
		{ AssetId = 6, Name = "red cool sword",     CreatorName = "f" }, -- 3: Substring (Unverified) -> 800 + 85 = 885
		{ AssetId = 3, Name = "private sword",      CreatorName = "c" }, -- 4: dropped (private)
		{ AssetId = 4, Name = "decal",             CreatorName = "d" }, -- 5: dropped (decal)
		{ AssetId = 5, Name = "timeout",            CreatorName = "e" }, -- 6: dropped (no info)
	}
	local infos = {
		[1] = { IsPublicDomain = true,  AssetTypeId = 10, Creator = { Name = "a", HasVerifiedBadge = false } },
		[2] = { IsPublicDomain = true,  AssetTypeId = 10, Creator = { Name = "b", HasVerifiedBadge = true } },
		[3] = { IsPublicDomain = true,  AssetTypeId = 10, Creator = { Name = "f", HasVerifiedBadge = false } },
		[4] = { IsPublicDomain = false, AssetTypeId = 10, Creator = { Name = "c", HasVerifiedBadge = false } },
		[5] = { IsPublicDomain = true,  AssetTypeId = 13, Creator = { Name = "d", HasVerifiedBadge = false } },
		-- [6] intentionally missing to simulate timeout/failure
	}

	local ranked = filterFreeModels(query, results, infos)

	if #ranked ~= 3 then
		return false, string.format(
			"filterFreeModels kept %d of 6 (expected 3: private, non-Model and info-less rows must all drop)",
			#ranked)
	end

	-- Expected order based on calculateScore:
	-- 1. "red sword v2" (Sim=0.9, Verified -> 900 + 90 + 500 = 1490)
	-- 2. "red sword" (Sim=1.0, Unverified -> 1000 + 95 = 1095)
	-- 3. "red cool sword" (Sim=0.8, Unverified -> 800 + 85 = 885)
	if ranked[1].id ~= 2 or ranked[2].id ~= 1 or ranked[3].id ~= 6 then
		return false, string.format("filterFreeModels ordered %d,%d,%d - expected 2,1,6 (verified prefix > unverified exact > unverified substring)",
			ranked[1].id, ranked[2].id, ranked[3].id)
	end

	return true
end

return Catalog