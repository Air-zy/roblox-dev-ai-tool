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

-- `owner/repo` is how a repository is written everywhere else, so it is accepted
-- as one word rather than made into two settings out of what is always copied as
-- one — and every other spelling reduces to it here, so `git clone` and `git
-- config remote` both get the reduction from one place. A URL is what is on the
-- clipboard after visiting a repository; retyping it as a slug was a step that
-- existed only because this refused to.
--
-- Only github.com is stripped, deliberately. Taking ANY host would turn
-- `https://gitlab.com/a/b` into a clone of github.com/a/b: a wrong answer
-- dressed as a working one. Left unmatched, the caller says what it accepts.
--
-- A /tree/<branch> or /blob/… URL does not match either, and that is the honest
-- outcome: the branch in it would have to be silently dropped or silently
-- obeyed, and `--branch` already spells it out loud.
Git.SLUG_FORMS = "owner/repo, or a github.com URL"

function Git.parseSlug(slug: string?): (string?, string?)
	local text = tostring(slug or "")
		:gsub("^%a[%w+.%-]*://", "")   -- https://
		:gsub("^[^/:@]+@", "")         -- git@, in the scp-style form
		:gsub("^www%.", "")
		:gsub("^github%.com[:/]", "")
		:gsub("%.git$", "")
		:gsub("/+$", "")
	return text:match("^([%w%-%._]+)/([%w%-%._]+)$")
end

function Git.setRemote(slug: string): (boolean, string?)
	local owner, repo = Git.parseSlug(slug)
	if not owner then
		return false, string.format("expected %s, got %q", Git.SLUG_FORMS, slug)
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
	-- A name that already carries an extension keeps it: `README.md` came out of
	-- a repository as a ModuleScript because .Source is the only place text lives
	-- here, and appending .luau would commit it back under a name the repository
	-- has never had. `Main` has no extension and gets the one its class implies.
	if Fs.carriesExtension(inst.Name) then
		return path, nil
	end
	return path .. suffix, nil
end

-- pathFor's inverse, for the one direction that reads a repository this place
-- did not write: which of a remote tree's paths to bring across.
--
-- Everything CAN come across. Fs.classFor answers ModuleScript for any suffix it
-- does not know, and .Source holds arbitrary text, so a README arrives as a
-- ModuleScript named `README.md` that cat, grep, sed and head all read with no
-- special case — and carriesExtension keeps the name honest on the way back out.
--
-- The default is still scripts only, and the reason is requests, not capability:
-- one blob apiece against 60 an hour unauthenticated, and Knit is 61 files of
-- which 6 are Luau. A default that spends ten times the budget to fetch a
-- .gitignore is the wrong default; `-A` is there for when the rest is wanted.
function Git.scriptPaths(remote: { [string]: string }, all: boolean?): ({ string }, number)
	local kept: { string } = {}
	local skipped = 0
	-- -A still stops at a file with NO extension. `LICENSE` as an Instance name is
	-- exactly what a script called LICENSE looks like, so nothing downstream can
	-- tell the two apart and pathFor would commit it back as LICENSE.luau —
	-- renaming a file the repository never renamed. Skipped and counted instead.
	for path in pairs(remote) do
		local leaf = path:match("[^/]+$") or path
		if Fs.stripScriptSuffix(leaf) or (all and Fs.carriesExtension(leaf)) then
			kept[#kept + 1] = path
		else
			skipped += 1
		end
	end
	table.sort(kept)
	return kept, skipped
end

export type InitContainer = { class: string, path: string, source: string }

-- Rojo's one convention that changes the SHAPE of what arrives: `src/init.luau`
-- does not mean a ModuleScript named init inside a folder named src, it means
-- the folder src IS that ModuleScript. Written the literal way, a cloned library
-- lands as Knit/src/init and `require(Packages.Knit.src)` finds a Folder.
--
-- Keyed by the container's ABSOLUTE path, the form resolve takes, because the
-- caller looks these up while walking a path it is building segment by segment.
-- A file with no directory above it is absent from the result: that would name a
-- service, and a service cannot be a script.
--
-- The test is stripScriptSuffix and never classFor, which answers ModuleScript
-- for every suffix it does not know and would take init.md for one of these.
function Git.initContainers(files: { { path: string, source: string } }): { [string]: InitContainer }
	local containers: { [string]: InitContainer } = {}
	for _, item in ipairs(files) do
		local dir, leaf = item.path:match("^(.+)/([^/]+)$")
		if dir and Fs.stripScriptSuffix(leaf) == "init" then
			local class = Fs.classFor(leaf)
			containers["/" .. dir] = { class = class, path = item.path, source = item.source }
		end
	end
	return containers
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
function Git.formatStatus(cfg: Config, status: Status, staged: { string },
	skipped: { string }, cap: number): string
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
	-- This section used to be absent, with a comment saying nothing stages yet.
	-- Staging arrived and the comment did not move, so `git add -A` was followed
	-- by a status that filed every staged path under "not staged" — and the index
	-- is what commit actually sends, which made the one thing worth reviewing the
	-- one thing that could not be seen.
	--
	-- A staged path that is no longer changed appears nowhere, which is what git
	-- does with one: the index here holds paths and not content, so "staged and
	-- identical to the remote" and "not staged" cannot be told apart, and the
	-- commit it produces is a no-op either way.
	local inIndex: { [string]: boolean } = {}
	for _, path in ipairs(staged) do
		inIndex[path] = true
	end
	local function split(paths: { string }): ({ string }, { string })
		local yes: { string } = {}
		local no: { string } = {}
		for _, path in ipairs(paths) do
			local into = inIndex[path] and yes or no
			into[#into + 1] = path
		end
		return yes, no
	end
	local stagedModified, modified = split(status.modified)
	local stagedAdded, added = split(status.added)
	local stagedDeleted, deleted = split(status.deleted)

	if #stagedModified + #stagedAdded + #stagedDeleted > 0 then
		out[#out + 1] = "Changes to be committed:"
		list(stagedModified, "modified:")
		list(stagedAdded, "new file:")
		list(stagedDeleted, "deleted:")
	end
	if #modified > 0 or #deleted > 0 then
		out[#out + 1] = "Changes not staged for commit:"
		list(modified, "modified:")
		list(deleted, "deleted:")
	end
	if #added > 0 then
		out[#out + 1] = "Untracked files:"
		list(added)
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

-- `path` narrows the log to the commits that touched one file. Handed over
-- ALREADY ENCODED: an instance name may carry a space, and the encoder is on
-- HttpService, which this module deliberately does not hold — every request it
-- describes is made by Shell.
function Git.logUrl(cfg: Config, count: number, path: string?): string
	local url = string.format("%s/repos/%s/%s/commits?sha=%s&per_page=%d",
		Git.HOST, cfg.owner, cfg.repo, cfg.branch, count)
	return path and (url .. "&path=" .. path) or url
end

-- One commit in full. The only endpoint here that returns a diff ALREADY
-- COMPUTED — the host renders each file's patch in unified format — which is why
-- `git show` costs one request and no diffing, where `git diff` costs one blob
-- apiece and does the work locally.
function Git.commitUrl(cfg: Config, sha: string): string
	return string.format("%s/repos/%s/%s/commits/%s", Git.HOST, cfg.owner, cfg.repo, sha)
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

	-- The index is what commit sends, so a status that files a staged path under
	-- "not staged" is a review of the wrong thing. It did exactly that for as
	-- long as staging has existed.
	local shown = Git.formatStatus(
		{ owner = "o", repo = "r", branch = "main" },
		{ modified = { "a.luau", "b.luau" }, added = { "c.luau" }, deleted = { "d.luau" } },
		{ "a.luau", "c.luau" }, {}, 100)
	if not shown:match("Changes to be committed:\n  modified:   a%.luau\n  new file:   c%.luau") then
		return false, "staged paths did not reach the committed section:\n" .. shown
	end
	if not shown:match("Changes not staged for commit:\n  modified:   b%.luau\n  deleted:    d%.luau") then
		return false, "unstaged paths did not stay unstaged:\n" .. shown
	end
	-- A staged new file is not untracked any more, and showing it in both places
	-- is how a reader double-counts what a commit is about to do.
	if shown:find("Untracked files:", 1, true) then
		return false, "a staged new file was also listed as untracked:\n" .. shown
	end

	-- clone reads a slug, a foreign tree and Rojo's init convention, and all
	-- three of those are pure. The slug pattern is shared with `git config
	-- remote`, so one of these failing is both of them broken.
	-- Every spelling that has to reduce to the same two words. The URL is what is
	-- actually on the clipboard, so it is not a convenience: refusing it was a
	-- retyping step with a typo in it waiting to happen.
	for _, form in ipairs({
		"Sleitnick/Knit", "https://github.com/Sleitnick/Knit",
		"https://github.com/Sleitnick/Knit.git", "https://github.com/Sleitnick/Knit/",
		"https://www.github.com/Sleitnick/Knit", "github.com/Sleitnick/Knit",
		"git@github.com:Sleitnick/Knit.git",
	}) do
		local owner, repo = Git.parseSlug(form)
		if owner ~= "Sleitnick" or repo ~= "Knit" then
			return false, string.format("%q parsed as %s/%s", form, tostring(owner), tostring(repo))
		end
	end
	for _, bad in ipairs({
		"Knit", "a/b/c", "", "a b/c",
		-- A host that is not GitHub must NOT reduce: this module speaks to
		-- api.github.com and nothing else, so accepting it would clone a
		-- different project of the same name and look like it worked.
		"https://gitlab.com/Sleitnick/Knit",
		-- Names a branch, which would have to be silently dropped or silently
		-- obeyed; `--branch` says it out loud instead.
		"https://github.com/Sleitnick/Knit/tree/main",
	}) do
		if Git.parseSlug(bad) then
			return false, string.format("%q parsed as a slug", bad)
		end
	end

	-- Fs.classFor answers ModuleScript for every suffix it does not know, so the
	-- filter has to be the suffix test itself. Without it a clone creates a
	-- ModuleScript named README.md, and spends a request fetching it first.
	local tree = {
		["src/init.luau"] = "a", ["src/Knit.client.luau"] = "b",
		["README.md"] = "c", ["default.project.json"] = "d", ["LICENSE"] = "e",
	}
	local kept, notScripts = Git.scriptPaths(tree)
	if #kept ~= 2 or kept[1] ~= "src/Knit.client.luau" or notScripts ~= 3 then
		return false, string.format("scriptPaths kept %d of the right 2 and skipped %d of 3",
			#kept, notScripts)
	end
	-- -A takes the files too, as ModuleScripts holding their own text — but NOT
	-- LICENSE. A name with no extension is indistinguishable from a script's, so
	-- pathFor would commit it back as LICENSE.luau, renaming a file the
	-- repository never renamed. The round trip is the property, not the count.
	local everything, unnameable = Git.scriptPaths(tree, true)
	if #everything ~= 4 or unnameable ~= 1 or everything[1] ~= "README.md" then
		return false, string.format("scriptPaths -A kept %d of the right 4 and skipped %d of 1",
			#everything, unnameable)
	end
	for _, path in ipairs(everything) do
		if path == "LICENSE" then
			return false, "an extensionless file was taken, and it cannot commit back"
		end
	end

	-- An init file means the CONTAINER is the script, which is the difference
	-- between a library that requires and one that does not.
	local inits = Git.initContainers({
		{ path = "Pkg/src/init.luau", source = "return 1" },
		{ path = "Pkg/src/Other.luau", source = "return 2" },
		{ path = "Pkg/svc/init.server.luau", source = "return 3" },
		{ path = "Pkg/notes/init.md", source = "hi" },
		{ path = "init.luau", source = "return 4" },
	})
	if not inits["/Pkg/src"] or inits["/Pkg/src"].class ~= "ModuleScript" then
		return false, "src/init.luau did not make src the ModuleScript"
	end
	if not inits["/Pkg/svc"] or inits["/Pkg/svc"].class ~= "Script" then
		return false, "init.server.luau did not carry its class through"
	end
	if inits["/Pkg/notes"] then
		return false, "init.md was taken for a script"
	end
	-- A file with no directory above it would name a SERVICE as the container,
	-- and a service cannot be a script.
	if inits["/"] or inits[""] then
		return false, "a top-level init.luau claimed a container"
	end

	return true
end

return Git
