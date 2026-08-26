--!strict
-- Git: the half of git that is pure computation over this vfs.
--
-- Object ids, the path mapping, the working-tree walk, and the comparison
-- against a remote tree. Deliberately no I/O: every request this plugin makes
-- goes through Shell's httpRequest, which is the one place that knows what
-- RequestAsync will and will not send, and a second caller would be a second
-- copy of those rules to keep right. What lives here is only the part that can
-- be tested without a network.
--
-- THERE IS NO LOCAL OBJECT DATABASE. The remote holds the objects; this module
-- only ever computes and compares IDS, so what has to be kept locally is a
-- handful of hashes rather than a copy of every script. That is the whole reason
-- the engine's native SHA-1 matters: without it, answering "did this change"
-- would mean storing the content to compare against.

local Fs = require(script.Parent.Parent:WaitForChild("fs"):WaitForChild("Fs"))

local isScript = Fs.isScript
local getSource = Fs.getSource
local instancePath = Fs.instancePath

-- Fetched once, through pcall, so a Studio without EncodingService reports one
-- clear "git needs this" instead of failing to load and taking the plugin with
-- it. Every id in git is a SHA-1 and there is no fallback worth writing.
local encodingOk, Encoding = pcall(function()
	return game:GetService("EncodingService")
end)
local SHA1 = Enum.HashAlgorithm.Sha1

local Git = {}

Git.HOST = "https://api.github.com"

-- Prefixed like every other key this plugin owns, and stored through the plugin
-- rather than in the DataModel: Team Create replicates the DataModel to every
-- collaborator, and the token must not go with it.
local KEY_OWNER  = "cc_git_owner"
local KEY_REPO   = "cc_git_repo"
local KEY_BRANCH = "cc_git_branch"
local KEY_TOKEN  = "cc_git_token"
local KEY_INDEX  = "cc_git_index"

local DEFAULT_BRANCH = "main"

local pluginRef: Plugin = nil :: any
local state = { owner = "", repo = "", branch = DEFAULT_BRANCH, token = "" }

-- Same shape as Settings.Initialize and wired from the same place. Reading the
-- settings here rather than on every call keeps `git status` off the plugin
-- store in its inner loop.
function Git.Initialize(p: Plugin)
	pluginRef = p
	local function read(key: string): string
		local value
		pcall(function()
			value = p:GetSetting(key)
		end)
		return type(value) == "string" and value or ""
	end
	state.owner = read(KEY_OWNER)
	state.repo = read(KEY_REPO)
	state.token = read(KEY_TOKEN)
	local branch = read(KEY_BRANCH)
	state.branch = branch ~= "" and branch or DEFAULT_BRANCH
	Git.loadIndex(read(KEY_INDEX))
end

export type Config = { owner: string, repo: string, branch: string }

function Git.config(): Config
	return { owner = state.owner, repo = state.repo, branch = state.branch }
end

function Git.token(): string
	return state.token
end

-- Which settings exist, so `git config` can reject a name instead of silently
-- writing one nothing will ever read.
local KEYS: { [string]: string } = {
	owner = KEY_OWNER, repo = KEY_REPO, branch = KEY_BRANCH, token = KEY_TOKEN,
}

function Git.setConfig(name: string, value: string): (boolean, string?)
	local key = KEYS[name]
	if not key then
		local names: { string } = {}
		for known in pairs(KEYS) do
			names[#names + 1] = known
		end
		table.sort(names)
		return false, string.format("unknown setting %q — there is %s",
			name, table.concat(names, ", "))
	end
	(state :: any)[name] = value
	if pluginRef then
		pcall(function()
			pluginRef:SetSetting(key, value)
		end)
	end
	return true
end

-- `owner/repo` is how a repository is written everywhere else, so accept it as
-- one word rather than making two settings out of what is always copied as one.
function Git.setRemote(slug: string): (boolean, string?)
	local owner, repo = slug:match("^([%w%-%._]+)/([%w%-%._]+)$")
	if not owner then
		return false, string.format("expected owner/repo, got %q", slug)
	end
	Git.setConfig("owner", owner)
	Git.setConfig("repo", repo)
	return true
end

-- Object ids

local function hex(s: string): string
	return (s:gsub(".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

-- git hashes `blob <bytes>\0<content>`, and the NUL is load-bearing: the id of
-- every object in every repository depends on hashing straight through it.
-- Verified against `git hash-object` and against the ids GitHub reports.
function Git.blobId(source: string): string
	return hex(Encoding:ComputeStringHash("blob " .. tostring(#source) .. "\0" .. source, SHA1))
end

-- The host wraps base64 at a fixed column, so the newlines have to go before
-- decoding or the decoder rejects the whole thing. Here rather than in Shell
-- because this is the module that already holds EncodingService.
function Git.decodeBase64(packed: string): (string?, string?)
	local ok, text = pcall(function()
		return buffer.tostring(Encoding:Base64Decode(buffer.fromstring((packed:gsub("%s", "")))))
	end)
	if not ok then
		return nil, tostring(text)
	end
	return text, nil
end

function Git.available(): (boolean, string?)
	if not encodingOk or not Encoding then
		return false, "this Studio has no EncodingService, and every git id is a SHA-1 it computes"
	end
	return true
end

-- Paths
--
-- The suffix carries the script class, the convention Rojo established, so a
-- repository written from here stays readable to everything else that reads
-- Roblox source out of git.
local SUFFIX: { [string]: string } = {
	ModuleScript = ".luau",
	Script = ".server.luau",
	LocalScript = ".client.luau",
}

-- nil for anything that is not a script, and nil with a REASON for a script that
-- cannot be named in git. A name may contain "/" — mesh imports produce them —
-- and that is the path separator, so such a script has no git path at all.
-- Reported rather than silently dropped: a file missing from a commit with
-- nothing said about it is the worst outcome available here.
function Git.pathFor(inst: Instance): (string?, string?)
	local suffix = SUFFIX[inst.ClassName]
	if not suffix then
		return nil, nil
	end
	local path = instancePath(inst):gsub("^/", "")
	if inst.Name:find("/", 1, true) then
		return nil, path .. ": the name contains \"/\", which is the path separator"
	end
	return path .. suffix, nil
end

export type Entry = { sha: string, inst: Instance, source: string }

-- The working tree: every script under `root`, by the path it would have in the
-- repository, with the id it would have as a blob.
--
-- Sources are kept because `git diff` needs them a moment later and reading them
-- again would mean a second pass through the editor for every open script. The
-- ids alone are what gets STORED; this table is per-command and short-lived.
function Git.walk(root: Instance): ({ [string]: Entry }, { string })
	local tree: { [string]: Entry } = {}
	local skipped: { string } = {}
	local scope = root:GetDescendants()
	table.insert(scope, 1, root)
	for _, inst in ipairs(scope) do
		if isScript(inst) then
			local path, why = Git.pathFor(inst)
			if why then
				skipped[#skipped + 1] = why
			elseif path then
				local source = getSource(inst) or ""
				tree[path] = { sha = Git.blobId(source), inst = inst, source = source }
			end
		end
	end
	table.sort(skipped)
	return tree, skipped
end

export type Status = {
	modified: { string },
	added: { string },
	deleted: { string },
}

-- Working tree against a remote tree, by id. Only the ids are compared, never
-- the text: two scripts with the same blob id ARE the same bytes, which is the
-- property the whole design leans on.
function Git.compare(working: { [string]: Entry }, remote: { [string]: string }): Status
	local status: Status = { modified = {}, added = {}, deleted = {} }
	for path, entry in pairs(working) do
		local remoteSha = remote[path]
		if not remoteSha then
			status.added[#status.added + 1] = path
		elseif remoteSha ~= entry.sha then
			status.modified[#status.modified + 1] = path
		end
	end
	for path in pairs(remote) do
		if not working[path] then
			status.deleted[#status.deleted + 1] = path
		end
	end
	table.sort(status.modified)
	table.sort(status.added)
	table.sort(status.deleted)
	return status
end

function Git.isClean(status: Status): boolean
	return #status.modified == 0 and #status.added == 0 and #status.deleted == 0
end

-- `git status`, rendered. Here rather than in the handler because it is pure:
-- the handler's half is one request, and a formatter behind a request is a
-- formatter nothing can test.
function Git.formatStatus(cfg: Config, status: Status, skipped: { string }, cap: number): string
	local head = string.format("On branch %s (%s/%s)", cfg.branch, cfg.owner, cfg.repo)
	if Git.isClean(status) and #skipped == 0 then
		return head .. "\nnothing to commit, working tree clean"
	end
	local out: { string } = { head }
	local function list(paths: { string }, label: string?)
		for index, path in ipairs(paths) do
			if index > cap then
				out[#out + 1] = string.format("  … %d more", #paths - cap)
				break
			end
			out[#out + 1] = label and string.format("  %-11s %s", label, path)
				or ("  " .. path)
		end
	end
	-- No staged section. Nothing stages yet, and an empty heading claiming
	-- otherwise would be a promise this cannot keep.
	if #status.modified > 0 or #status.deleted > 0 then
		out[#out + 1] = "Changes not staged for commit:"
		list(status.modified, "modified:")
		list(status.deleted, "deleted:")
	end
	if #status.added > 0 then
		out[#out + 1] = "Untracked files:"
		list(status.added)
	end
	-- Named, never dropped. A script missing from a commit with nothing said
	-- about it is the worst outcome this module can produce.
	if #skipped > 0 then
		out[#out + 1] = "Cannot be versioned:"
		list(skipped)
	end
	return table.concat(out, "\n")
end

-- The index
--
-- Paths only, never content. `git commit` reads each staged path's source at the
-- moment it commits, which is what keeps this a list of strings rather than the
-- object database this module refuses to grow.

local index: { [string]: boolean } = {}

local function saveIndex()
	if not pluginRef then
		return
	end
	local paths: { string } = {}
	for path in pairs(index) do
		paths[#paths + 1] = path
	end
	table.sort(paths)
	pcall(function()
		pluginRef:SetSetting(KEY_INDEX, table.concat(paths, "\n"))
	end)
end

function Git.loadIndex(raw: string?)
	index = {}
	for path in tostring(raw or ""):gmatch("[^\n]+") do
		index[path] = true
	end
end

function Git.staged(): { string }
	local paths: { string } = {}
	for path in pairs(index) do
		paths[#paths + 1] = path
	end
	table.sort(paths)
	return paths
end

function Git.stage(paths: { string })
	for _, path in ipairs(paths) do
		index[path] = true
	end
	saveIndex()
end

function Git.unstage(paths: { string }?)
	if not paths then
		index = {}
	else
		for _, path in ipairs(paths) do
			index[path] = nil
		end
	end
	saveIndex()
end

-- Every path a commit could touch: changed locally, or gone from the working
-- tree. `git add -A` means these and nothing else.
function Git.changedPaths(status: Status): { string }
	local paths: { string } = {}
	table.move(status.modified, 1, #status.modified, #paths + 1, paths)
	table.move(status.added, 1, #status.added, #paths + 1, paths)
	table.move(status.deleted, 1, #status.deleted, #paths + 1, paths)
	table.sort(paths)
	return paths
end

-- The tree payload
--
-- git's mode for an ordinary file. The API takes it PADDED, unlike the bytes of
-- a real tree object, which store 40000 for a directory rather than 040000 —
-- one of the two places this format contradicts how it is displayed.
local BLOB_MODE = "100644"

-- A deleted path is `"sha": null`, and Luau has no value that JSONEncode turns
-- into null: a nil field is simply absent, which would read as "leave it alone"
-- and silently keep the file. So the entry carries a sentinel that is swapped
-- for null after encoding.
--
-- ponytail: sentinel + one gsub rather than a JSON writer of our own. The
-- ceiling is a source file that contains the sentinel verbatim, which
-- Git.encodeTree refuses rather than corrupting. Write a real encoder if that
-- ever stops being absurd.
-- Alphanumeric and underscores only: JSONEncode escapes control characters as
-- \uXXXX, so a sentinel built from those would not survive encoding as the
-- bytes this looks for. Nothing here is magic in a Lua pattern either.
local NULL = "__git_null_7f3a9c__"
Git.NULL = NULL

export type TreeEntry = { path: string, mode: string, type: string, content: string?, sha: string? }

-- What POST /git/trees is handed: one entry per staged path, content inline so
-- the blobs are created by the same request rather than one apiece.
function Git.treePayload(working: { [string]: Entry }, staged: { string }): { TreeEntry }
	local entries: { TreeEntry } = {}
	for _, path in ipairs(staged) do
		local entry = working[path]
		if entry then
			entries[#entries + 1] = {
				path = path, mode = BLOB_MODE, type = "blob", content = entry.source,
			}
		else
			-- Staged but no longer in the working tree: a deletion.
			entries[#entries + 1] = {
				path = path, mode = BLOB_MODE, type = "blob", sha = NULL,
			}
		end
	end
	return entries
end

-- Content goes inline, so a commit of everything is one request the weight of the
-- whole repository: 1.2 MB measured on a place with 76 scripts. RequestAsync
-- documents a RATE limit (500/min) and says nothing about size, so rather than
-- depend on a ceiling nobody has written down, the tree is built in chunks that
-- chain through base_tree — chunk N+1 is built ON the tree chunk N produced, and
-- only the last one is committed. The result is one commit either way.
--
-- ponytail: 512 KB a chunk, chosen to sit well under any plausible ceiling rather
-- than measured against a real one. Raise it if the extra round trips ever cost
-- more than the caution buys.
local CHUNK_BYTES = 512 * 1024

function Git.chunkPayload(entries: { TreeEntry }, budget: number?): { { TreeEntry } }
	local cap = budget or CHUNK_BYTES
	local chunks: { { TreeEntry } } = {}
	local current: { TreeEntry } = {}
	local size = 0
	for _, entry in ipairs(entries) do
		local weight = #entry.path + #(entry.content or "")
		-- One entry over budget still has to go somewhere, and a blob cannot be
		-- split, so it takes a chunk of its own rather than being dropped.
		if #current > 0 and size + weight > cap then
			chunks[#chunks + 1] = current
			current, size = {}, 0
		end
		current[#current + 1] = entry
		size += weight
	end
	if #current > 0 then
		chunks[#chunks + 1] = current
	end
	return chunks
end

-- The check the whole design rests on: the remote hashed the blobs it wrote, and
-- this end hashed them before sending. Fed the FINISHED tree read back
-- recursively, because a tree response carries top-level entries only and a
-- nested path never appears in one — comparing against that response instead
-- matched nothing and quietly passed.
function Git.verifyTree(created: { [string]: string }, working: { [string]: Entry },
	staged: { string }): (boolean, string?)
	for _, path in ipairs(staged) do
		local mine = working[path]
		local theirs = created[path]
		if not mine then
			-- Staged with nothing behind it is a deletion, so its absence is the
			-- correct outcome and its presence is the failure.
			if theirs then
				return false, path .. " was staged for deletion but is still in the tree"
			end
		elseif not theirs then
			return false, path .. " was staged but is missing from the tree the remote built"
		elseif theirs ~= mine.sha then
			return false, string.format("%s hashed to %s here and %s there",
				path, mine.sha:sub(1, 10), theirs:sub(1, 10))
		end
	end
	return true
end

-- Swap the sentinel for a real null, and refuse rather than mangle a file that
-- happens to contain it.
function Git.encodeTree(json: string): (string?, string?)
	local body = (json:gsub('"' .. NULL .. '"', "null"))
	-- Anything still holding the sentinel has it INSIDE a value rather than as
	-- one, which means a staged script contains it. Refuse rather than ship a
	-- commit with a corrupted entry.
	if body:find(NULL, 1, true) then
		return nil, "a staged script contains this build's null sentinel verbatim, " ..
			"which would corrupt the commit"
	end
	return body, nil
end

-- URLs, in one place so the API's shape is written down once.

-- `ref` is a branch name for reading the working state, or a tree sha for reading
-- back one this session just created. The API takes either in the same slot.
function Git.treeUrl(cfg: Config, ref: string?): string
	return string.format("%s/repos/%s/%s/git/trees/%s?recursive=1",
		Git.HOST, cfg.owner, cfg.repo, ref or cfg.branch)
end

function Git.blobUrl(cfg: Config, sha: string): string
	return string.format("%s/repos/%s/%s/git/blobs/%s", Git.HOST, cfg.owner, cfg.repo, sha)
end

-- One request that carries BOTH halves a commit needs: the head commit to parent
-- from, and the tree to build on. Asking /git/ref and then /git/commits would be
-- two round trips for the same two fields.
function Git.branchUrl(cfg: Config): string
	return string.format("%s/repos/%s/%s/branches/%s", Git.HOST, cfg.owner, cfg.repo, cfg.branch)
end

function Git.newTreeUrl(cfg: Config): string
	return string.format("%s/repos/%s/%s/git/trees", Git.HOST, cfg.owner, cfg.repo)
end

function Git.newCommitUrl(cfg: Config): string
	return string.format("%s/repos/%s/%s/git/commits", Git.HOST, cfg.owner, cfg.repo)
end

function Git.logUrl(cfg: Config, count: number): string
	return string.format("%s/repos/%s/%s/commits?sha=%s&per_page=%d",
		Git.HOST, cfg.owner, cfg.repo, cfg.branch, count)
end

-- Which remote paths differ from what is here. Pull fetches exactly these, and
-- nothing else: a blob whose id already matches is the same bytes by definition.
function Git.incoming(working: { [string]: Entry }, remote: { [string]: string }): { string }
	local paths: { string } = {}
	for path, sha in pairs(remote) do
		local mine = working[path]
		if not mine or mine.sha ~= sha then
			paths[#paths + 1] = path
		end
	end
	table.sort(paths)
	return paths
end

-- The suffix written by pathFor has to be the suffix Fs.classFor reads back, or
-- a commit and the pull that follows it would disagree about what class a script
-- is. Checked rather than assumed, because the two tables live in two files.
function Git.suffixesAgree(classFor: (string) -> (string, string)): (boolean, string?)
	for className, suffix in pairs(SUFFIX) do
		local roundTrip, bare = classFor("Probe" .. suffix)
		if roundTrip ~= className then
			return false, string.format("%s writes %s, which reads back as %s",
				className, suffix, roundTrip)
		end
		if bare ~= "Probe" then
			return false, string.format("%s leaves the name as %q", suffix, bare)
		end
	end
	return true
end

-- Moving an existing branch is a PATCH to the branch's own ref; CREATING one is
-- a POST to the collection with the fully qualified name in the body. Two URLs
-- because they are two different endpoints, not one with a different verb.
function Git.newRefUrl(cfg: Config): string
	return string.format("%s/repos/%s/%s/git/refs", Git.HOST, cfg.owner, cfg.repo)
end

function Git.refName(cfg: Config): string
	return "refs/heads/" .. cfg.branch
end

function Git.refUrl(cfg: Config): string
	return string.format("%s/repos/%s/%s/git/refs/heads/%s", Git.HOST, cfg.owner, cfg.repo, cfg.branch)
end

-- Reads of a public repository need no token at all, so the header is added only
-- when there is one. The API version is pinned because an unpinned request gets
-- whatever GitHub defaults to that month.
function Git.headers(): { [string]: string }
	local headers: { [string]: string } = {
		["Accept"] = "application/vnd.github+json",
		["X-GitHub-Api-Version"] = "2022-11-28",
	}
	if state.token ~= "" then
		headers["Authorization"] = "Bearer " .. state.token
	end
	return headers
end

function Git.configured(cfg: Config): (boolean, string?)
	if cfg.owner == "" or cfg.repo == "" then
		return false, "no remote — `git config remote <owner>/<repo>` sets one"
	end
	return true
end

-- Everything here is pure but for the two engine calls, and both of those are
-- checked against values git itself produces rather than against this file's own
-- arithmetic. Chained from Shell.selfTest, which owns the handler's half.
function Git.selfTest(): (boolean, string?)
	if not Git.available() then
		-- Nothing else in this module can run without it, and saying so once is
		-- more useful than eleven failures that all mean the same thing.
		return true
	end

	-- The empty blob is the id every repository on earth shares, and `hello\n` is
	-- the next cheapest known value. Between them they prove the header, the
	-- embedded NUL and the digest are all still right — which is the assumption
	-- every other line in this file rests on.
	if Git.blobId("") ~= "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" then
		return false, "the empty blob id is wrong: " .. Git.blobId("")
	end
	if Git.blobId("hello\n") ~= "ce013625030ba8dba906f756967f9e9ca394464a" then
		return false, "the blob id for 'hello\\n' is wrong: " .. Git.blobId("hello\n")
	end

	-- The remote wraps base64 at a fixed column and the decoder rejects the
	-- newlines unless they go first. Every diff and every pull reads a file
	-- through this.
	local decoded, decodeErr = Git.decodeBase64("bG9jYWwgeCA9IDEKcmV0\ndXJuIHgK")
	if decoded ~= "local x = 1\nreturn x\n" then
		return false, "wrapped base64 did not decode: " .. tostring(decoded or decodeErr)
	end

	-- The suffix a commit WRITES has to be the suffix a pull READS BACK, and the
	-- two tables live in two files. Drift turns a ModuleScript into a Script on a
	-- round trip, silently.
	local agree, agreeErr = Git.suffixesAgree(Fs.classFor)
	if not agree then
		return false, "git and Fs disagree about script suffixes: " .. tostring(agreeErr)
	end
	-- ...and the checker has to be capable of saying no.
	if Git.suffixesAgree(function()
		return "Folder", "X"
	end) then
		return false, "suffixesAgree accepts a mapping that disagrees"
	end

	-- A deletion is `"sha": null`, which Luau cannot encode, so it travels as a
	-- sentinel that one gsub swaps out. If that ever stopped firing, every
	-- deletion would silently become "leave this file alone".
	local deletion = Git.treePayload({}, { "gone.luau" })
	if #deletion ~= 1 or deletion[1].sha ~= NULL or deletion[1].content ~= nil then
		return false, "a staged path with nothing behind it is not shaped as a deletion"
	end
	local swapped = Git.encodeTree('{"sha":"' .. NULL .. '"}')
	if swapped ~= '{"sha":null}' then
		return false, "the null sentinel did not become null: " .. tostring(swapped)
	end
	-- ...and a script that contains it verbatim is refused rather than corrupted.
	if Git.encodeTree('{"content":"-- ' .. NULL .. ' --"}') then
		return false, "a payload carrying the sentinel inside a value was accepted"
	end

	-- Chunking has to lose nothing and never emit an empty chunk, since one
	-- entry over budget still has to ship and a blob cannot be split.
	local sample: { TreeEntry } = {}
	for index = 1, 5 do
		sample[index] = { path = "p" .. index, mode = "100644", type = "blob",
			content = string.rep("x", 400) }
	end
	local chunks = Git.chunkPayload(sample, 1000)
	local counted = 0
	for _, chunk in ipairs(chunks) do
		if #chunk == 0 then
			return false, "chunkPayload emitted an empty chunk"
		end
		counted += #chunk
	end
	if counted ~= #sample then
		return false, string.format("chunkPayload lost entries: %d of %d", counted, #sample)
	end
	if #Git.chunkPayload({ sample[1] }, 1) ~= 1 then
		return false, "an entry over budget was dropped instead of taking its own chunk"
	end

	return true
end

return Git
