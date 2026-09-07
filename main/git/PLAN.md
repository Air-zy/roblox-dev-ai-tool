# Authentic Git Roadmap

Status: design plan, not yet implemented.
- note from me (human) THESE ARE NOT STRICT instructions.. feel free to make open suggestion/changes

This document defines how the plugin's Git support should grow from a useful
GitHub tree synchronizer into a Git-shaped version-control system whose common
commands have the semantics Git users expect. The transport may remain GitHub's
REST API; authenticity here means the state model, safety rules, and command
behavior are Git-compatible, not that Roblox Studio must implement the smart
HTTP pack protocol or every Git command.

This is deliberately a **source-only Git client**. Its working-tree files are
only the `.Source` values of `ModuleScript`, `Script`, and `LocalScript` objects.
It does not serialize Parts, Models, WorldModels, properties, attributes, tags,
object references, terrain, assets, or any other Instance state. Non-script
Instances may be traversed as directory-like containers, but they are not Git
content.

## Why this work is needed

The current implementation already has valuable pieces:

- real SHA-1 blob IDs;
- a DataModel-to-repository path mapping;
- a persistent list of staged paths;
- status, diff, clone, log, show, pull, and remote commits through GitHub's Git
  database API;
- fast-forward protection supplied by GitHub when a branch ref is updated; and
- tokens kept in plugin settings instead of the replicated DataModel.

Its state model is not yet Git's state model:

- `git add` remembers a path, then `git commit` rereads that path. An edit made
  after `git add` is therefore committed even though it was never staged.
- `git commit` creates remote objects and moves the remote branch. It is commit
  and push in one operation, and there is no `git push` command.
- `git status` compares the working tree directly with the remote tree. It does
  not independently compare HEAD -> index and index -> working tree.
- `git pull` writes remote versions into the DataModel. It does not mean fetch
  followed by fast-forward, merge, or rebase, and it intentionally never applies
  remote deletions.
- There is no local HEAD, local branch, remote-tracking ref, commit graph, or
  durable content-addressed object store.
- `git clone` imports files but intentionally does not configure `origin`.
- authentication is a pasted PAT. `/login` belongs to the selected AI provider,
  not GitHub.

The first goal is to correct those meanings. Breadth comes afterward.

## Product contract

### Target workflow

```text
git login
git clone owner/repo /ServerScriptService/Game
git switch -c feature/save-system

# Edit scripts in Studio.
git status
git add ServerScriptService/Game/SaveService.server.luau
# More edits after add remain unstaged.
git diff --staged
git commit -m "Add save retries"
# The commit is local; GitHub has not moved yet.
git push -u origin feature/save-system

git fetch
git status
git pull --ff-only
```

An existing container can also be the worktree root. For example,
`git clone owner/repo /Workspace/MyWorldModel` may populate an existing, empty
`WorldModel` with scripts, and a repository rooted higher in the hierarchy may
contain paths such as `Workspace/MyWorldModel/Controller.server.luau`. The
`WorldModel` itself is not committed; only script sources beneath it are.

### Required invariants

1. **Only source is versioned.** The projected worktree contains only
   `ModuleScript`, `Script`, and `LocalScript` source. Existing non-script
   containers may locate those scripts but may never be serialized, staged,
   diffed, committed, overwritten, or deleted by Git.
2. **Working tree, index, HEAD, and upstream are distinct.** No command may
   silently substitute one for another.
3. **The index stores content, not intentions.** `git add` snapshots the exact
   blob and mode that a later commit will use.
4. **Commit never updates a remote ref.** Only `push` may publish local commits.
5. **Fetch never edits the DataModel.** It updates remote-tracking refs and
   downloads metadata/objects only.
6. **Pull is fetch plus an explicit integration policy.** Begin with
   fast-forward-only behavior; add three-way merge only after conflicts are
   represented safely.
7. **Push is non-forcing by default.** It must reject non-fast-forward updates
   and report the fetch/pull command that resolves them. Force push requires the
   fully explicit `--force-with-lease`; plain `--force` is out of scope until a
   protected recovery design exists.
8. **Destructive worktree changes are atomic and undoable.** Continue routing
   DataModel mutations through `Fs.withUndo`, and fetch all required content
   before opening the undo recording.
9. **No secret enters the DataModel, transcript, command output, or error body.**
   Credentials remain separate from repository state and are redacted at every
   display boundary.
10. **A failed operation leaves valid state.** Persistent metadata uses schema
   versions, checksums, and a write-new-then-swap protocol.
11. **Remote state is never guessed.** A stale lease, missing object, truncated
    tree, unsupported path, or ambiguous mapping produces a refusal with a
    recovery command.

## Scope boundaries

The plugin should implement the porcelain needed for normal Studio collaboration:

- `init`, `clone`, `status`, `diff`, `add`, `restore`, `reset`;
- `commit`, `log`, `show`;
- `remote`, `branch`, `switch`;
- `fetch`, `pull --ff-only`, a safe three-way `merge`, and `push`;
- `login`, `logout`, and `auth status` under the `git` command; and
- a compatibility path for fine-grained personal access tokens.

The following are non-goals for the first complete version:

- the native Git wire protocol, packfiles, delta compression, SSH, or Git LFS;
- submodules, hooks, signed commits, notes, bisect, worktrees, sparse checkout,
  or partial clone;
- versioning non-script Instances or any Instance properties, attributes, tags,
  references, assets, terrain, or binary Roblox data;
- materializing repository files that are not recognized `.lua`/`.luau` source
  files; and
- byte-for-byte compatibility with `.git` on disk, because a Studio plugin does
  not have a normal repository filesystem.

Unsupported commands must fail by name and explain the nearest supported
workflow. They must never silently approximate another Git operation.

## Repository and path model

### Explicit worktree root

A repository needs a root within the DataModel. Persist a canonical instance path
such as `/ServerScriptService/Game`; do not assume every script under `game`
belongs to one repository. All repository paths are relative to that root.

`git init [path]` initializes that root. `git clone <remote> [path]` initializes
it, configures `origin`, sets the checked-out branch and upstream, populates the
index and HEAD, and then materializes the worktree. Preserve the old one-off
library behavior under a deliberately different command or flag, such as
`git import`, so an import cannot accidentally become the next push target.

Repository identity must not rely only on `PlaceId`: unpublished places share
zero, places may be copied, and one place may contain multiple repository roots.
Use a generated repository ID in plugin settings, indexed by a best-effort place
identity plus worktree path. Detect ambiguous or moved roots and ask the user to
rebind rather than selecting one silently.

### Source-only projection and container behavior

Git stores files and directories; Studio stores scripts beneath arbitrary
Instance hierarchies. Keep that translation as a policy layer separate from the
object database. The projected working tree follows these rules:

- `ModuleScript` maps to `Name.luau`;
- `Script` maps to `Name.server.luau`;
- `LocalScript` maps to `Name.client.luau`;
- the corresponding `.lua` spellings are accepted on pull for compatibility;
- only `.Source` is blob content—script properties, attributes, tags, RunContext,
  and children are not part of that blob;
- source reads continue to use `Fs.getSource`, including the current unsaved
  Script Editor buffer when a document is open;
- source writes continue to use the editor-aware `Fs` path so an open document
  and its visible buffer cannot silently diverge;
- Rojo-style `init.luau`, `init.server.luau`, and `init.client.luau` map a script
  that also acts as a container, with round-trip tests for each class;
- names that cannot round-trip are rejected and reported rather than sanitized
  or silently skipped; and
- class changes naturally appear as deletion of one suffixed path and addition
  of another unless explicit rename detection is added later.

Every existing non-script Instance under the repository root—including a
`WorldModel`, `Model`, `Folder`, service, configuration object, or Part—may act
as a directory while locating descendant scripts. Git operations must not read
or write that container's properties and must not require it to be a Folder.

When a pulled path needs a missing intermediate container, the plugin may create
a `Folder` solely as directory structure. A repository has no source-only way to
say that a directory should be a `WorldModel` or `Model`, so it must never guess
another class. To pull into a `WorldModel`, create or select that `WorldModel`
first and use it as the repo root or as an existing ancestor. Empty containers
are invisible to Git and are never removed automatically.

Pull, switch, restore, and merge may create, update, or delete only the three
supported script classes (plus missing structural Folders). Before deleting or
replacing a script that has non-script descendants, refuse the operation: deleting
the script would also destroy unversioned Instances. The error must name the
blocked script and leave the whole operation unchanged.

Remote repositories may contain README files, JSON, project files, images, and
other unsupported blobs. Keep their modes and object SHAs as opaque entries in
HEAD/index trees so a source-only commit preserves them unchanged, but never
materialize them as ModuleScripts. `git status`, `git diff`, and `git add -A`
ignore opaque entries. The current `clone -A` behavior that turns arbitrary text
into ModuleScripts should be retired rather than carried into the authentic
mode.

The Git core consumes a virtual source table (`path`, `mode`, `bytes`) plus
opaque tree entries and must not know about Instances. The mapping layer is the
only code that traverses containers or writes script Source in the DataModel.

## Persistent state

Introduce a versioned repository record conceptually shaped like this:

```text
RepositoryState
  schemaVersion
  repositoryId
  worktreeRoot
  head = { symbolic = "refs/heads/main" } | { detached = <commit-sha> }
  refs/heads/* = <commit-sha>
  refs/remotes/origin/* = <commit-sha>
  branches/* = { upstreamRemote, upstreamBranch }
  remotes/origin = { owner, repo, fetchRefspec, pushRefspec }
  index[path] = { mode, blobSha, objectKey, stage, projectedSource }
  mergeState = nil | { originalHead, mergeHead, conflicts }
  objects = manifest of locally retained blobs, trees, and commits
```

Credentials are intentionally absent. Store authentication in a separate,
global credential record keyed by host and account. Store author name/email as
normal user configuration, not as authentication identity.

### Storage backend

Add a small storage interface instead of scattering `Plugin:GetSetting` and
`Plugin:SetSetting` calls through Git logic:

```text
loadRepository(id) -> state
saveRepository(id, expectedRevision, state) -> newRevision
getObject(id, sha) -> kind, bytes
putObject(id, kind, sha, bytes)
deleteUnreachableObjects(id, reachableSet)
loadCredential(host) / saveCredential(host, credential)
```

Before choosing chunk sizes, write a Studio probe that measures practical plugin
setting limits, restart persistence, failure behavior, and the cost of many keys.
Do not assume an undocumented capacity. Store only objects needed by the index,
unpushed commits, merge state, and recent operations; remote objects may be
re-fetched. If a required object cannot be persisted, fail the staging or commit
before claiming success.

Use content-addressed keys and a manifest so interrupted writes are recoverable.
Write objects first, then the new state generation, verify it, and finally swap a
small active-generation pointer. Garbage collection may remove only objects that
are unreachable from every local ref, index entry, or in-progress operation.

### Migration

Read the current `cc_git_*` settings once:

- carry owner/repo/branch and the PAT into the new remote and credential stores;
- do not pretend the old staged path list contains snapshots. Mark it as needing
  review and require `git add` again;
- initialize HEAD and `origin/<branch>` from one verified fetch;
- keep the old keys until the new generation has been read back successfully;
  and
- make migration idempotent so a Studio crash can safely retry it.

## Git object model

Extend `Git.lua` as the pure object/state core:

- blob encoding and SHA-1 (already present);
- canonical nested tree construction, Git tree ordering, binary tree encoding,
  and exact tree SHA-1;
- canonical commit payloads with tree, zero or more parents, author, committer,
  timestamps, timezone, blank separator, and message;
- commit SHA-1 calculation;
- ref ancestry and merge-base traversal;
- index/tree/status comparison; and
- reachability for safe pruning and ahead/behind counts.

Add fixed vectors produced by desktop Git for empty blobs, nested trees, root
commits, normal commits, Unicode names, CRLF content, and multiple parents. Every
object uploaded through GitHub must return the SHA computed locally. A mismatch
aborts before a ref update.

The repository object model hashes exact bytes, while the Studio write boundary
already normalizes CRLF because Roblox's source APIs require it. Define and test
that boundary explicitly so a pull followed by status does not repeatedly dirty
the same script. Never normalize opaque, non-source blobs.

## Command semantics

### `git status` and `git diff`

Compute three comparisons:

```text
HEAD tree -> index             staged changes
index -> mapped working tree  unstaged changes
local HEAD -> upstream        ahead/behind/diverged
```

`git diff` shows index -> worktree. `git diff --staged` shows HEAD -> index.
`git status --short --branch` should provide stable porcelain output suitable for
the agent, while the default status remains readable for a person. Both commands
operate exclusively on Source text. Container classes/properties and unsupported
remote files cannot appear as modifications.

### `git add`, `restore`, and `reset`

`git add <path>` stores the current mode, blob bytes, and blob SHA in the index.
Deletion is represented by absence from the new index, not by a magic path list.
`git add -A` snapshots additions, modifications, and deletions within the repo
root, but only for the three supported script classes. A later Source edit must
appear as unstaged and must not affect commit. Opaque remote entries remain in
the index unchanged.

Implement unambiguous safe forms first:

- `git restore --staged <path>` copies HEAD's entry to the index;
- `git restore <path>` copies the index entry to the worktree through one undo
  recording;
- `git reset --mixed <commit>` moves the current branch and resets the index but
  preserves the worktree; and
- `git reset --hard <commit>` is delayed until preview, confirmation policy, and
  complete undo behavior are proven.

### `git commit`

Commit builds a tree strictly from the index, writes a local commit object, moves
the checked-out local branch, and leaves the worktree untouched. It does not need
GitHub and does not update `refs/remotes/*`. Support root commits and merge commits
in the object model even if merge arrives later.

Require configured `user.name` and `user.email`; do not infer an email from a
token. Reject an empty commit unless `--allow-empty` is explicitly supported.

### `git fetch`

Fetch resolves remote refs, downloads the commit/tree metadata needed for graph
operations, validates every returned object ID, then atomically advances
`refs/remotes/origin/*`. It never changes HEAD, the index, or the DataModel.

Handle GitHub's recursive-tree `truncated` response by walking subtrees. Respect
ETags and conditional requests where useful, surface primary and secondary rate
limits distinctly, and cap graph traversal with a continuation that cannot be
mistaken for a complete history.

### `git push`

Push uploads missing blobs, nested trees, and commits reachable from the local
branch, verifies returned SHAs, and updates the remote ref last. Send
`force: false` explicitly for a normal push. The expected remote SHA is the
remote-tracking ref; if the live ref differs, reject as stale even when GitHub
would otherwise accept the update.

`--force-with-lease` may update only when the live remote ref equals the lease
the user last fetched. Print which local and remote refs moved, then advance the
remote-tracking ref only after the server confirms success. A partial object
upload is harmless; a partial ref update is not reported as success.

### `git merge` and `git pull`

Ship pull in two steps:

1. `git pull --ff-only` fetches and advances the local branch, index, and
   worktree only when local HEAD is an ancestor of upstream. Dirty changes that
   would be overwritten refuse the operation.
2. Add a real three-way merge after merge-base discovery and conflict state are
   durable. Script Source may use diff3 conflict markers. Delete/modify,
   add/add, rename ambiguity, and non-text mappings remain explicit conflicts.

A merge applies all clean results and conflict markers in one undo recording,
stores stages 1/2/3 for conflicted index paths, and writes `MERGE_HEAD`-equivalent
state. `git status` lists unmerged paths. `git add` marks a conflict resolved;
`git commit` completes it. `git merge --abort` restores original HEAD, index, and
worktree from persisted pre-merge objects.

Never leave half a pull in the DataModel. Download and validate every required
blob before beginning the mutation.

### Branches and clone

- `git branch` lists local branches and upstream/ahead/behind state.
- `git branch <name>` creates a ref at HEAD.
- `git switch <name>` refuses when changes would be overwritten, then updates
  HEAD, index, and worktree atomically.
- `git switch -c <name>` creates and checks out a branch.
- Detached HEAD may be read-only at first; explain how to create a branch before
  committing.
- `git clone` discovers the default branch, configures `origin`, fetches objects,
  initializes HEAD/index, and projects only supported source into the selected
  DataModel root. It must not silently use `main`.
- An existing `WorldModel`, `Model`, Folder, or service can be the selected root.
  Clone/pull writes supported script descendants there normally while preserving
  the container and all non-script descendants.

## GitHub authentication

Add Git-specific commands so they cannot be confused with AI-provider `/login`:

```text
git login
git auth status
git logout
git config token <fine-grained-pat>   # compatibility/recovery path
```

Preferred design: register a GitHub App with device flow enabled, repository
**Contents: read and write**, and only the metadata permission GitHub requires.
Ship its public client ID, never a client secret. `git login` requests a device
code, displays the user code and `https://github.com/login/device`, polls at the
server-provided interval, handles `authorization_pending`, `slow_down`, expiry,
denial, and cancellation, then verifies the identity through GitHub before
storing the token. Repository access remains limited by both the user and the
GitHub App installation.

Support expiring user tokens and refresh tokens if enabled for the app. Refresh
must be single-flight; a second 401 after refresh logs out rather than looping.
`git auth status` shows account, host, expiry, and access to the configured repo,
never token text. `git logout` clears access token, refresh token, device-flow
state, and cached identity. PATs remain useful for self-hosting or recovery and
must be accepted only through a redacted input path where possible.

Before release, document that plugin settings are local persistence, not a
hardware-backed secret store. Users must be able to revoke the GitHub App from
GitHub, and errors should link to that recovery path without echoing credentials.

## Code organization

Keep the dependency direction explicit:

```text
fs/Shell.lua
  -> git/Commands.lua       parse-independent command orchestration
       -> git/Git.lua       pure Git objects, refs, index, graph, status
       -> git/Merge.lua     pure merge-base and three-way text merge
       -> git/GitHub.lua    GitHub REST adapter; injected HTTP transport
       -> git/Store.lua     versioned repository/object persistence
       -> git/Auth.lua      GitHub device flow and credential refresh
       -> fs/Fs.lua         mapping and undoable DataModel mutation
```

Do not copy the generic HTTP restrictions currently centralized in `Shell.lua`.
Extract or inject that transport so curl, wget, GitHub, and auth share one request
implementation and one redaction/error policy. `Shell.lua` should retain argv
parsing and delegate the `git` subcommand after parse.

Every new pure module exports `selfTest`. Network integration tests are opt-in
and must never run during plugin startup.

## Delivery phases

### Phase 0 - Characterize and freeze behavior

- Add golden tests for every existing Git command and its refusal paths.
- Add a storage-limit/restart probe for Studio plugin settings.
- Record current GitHub request counts and test public/private/rate-limited errors.
- Choose a versioned state schema and write migration fixtures.
- Update the pinned GitHub API version deliberately; do not silently float it.

Exit gate: current functionality is captured well enough that later semantic
changes are intentional and migration can be tested.

### Phase 1 - Correct index and status

- Add explicit repository root, HEAD tree, and snapshot-bearing index.
- Make `add` snapshot bytes and deletion state.
- Make status/diff compare HEAD/index/worktree correctly.
- Add `restore --staged` and safe worktree restore.
- Migrate old config while invalidating old path-only staging safely.

Exit gate: editing a file after `git add` produces both staged and unstaged
changes, and commit inputs exactly match `git diff --staged`.

### Phase 2 - Local refs, objects, and commits

- Implement durable blob/tree/commit objects and exact SHA tests.
- Add local branches, symbolic/detached HEAD, identity config, and local log/show.
- Change commit to move only the local branch.
- Add object reachability and conservative garbage collection.

Exit gate: commits survive a Studio restart without network access and do not
change GitHub.

### Phase 3 - GitHub login, fetch, and push

- Add GitHub App device login plus PAT fallback and token refresh.
- Move GitHub API code behind the adapter.
- Implement remote discovery, fetch, remote-tracking refs, push, upstream setup,
  and non-fast-forward/lease protection.
- Verify every uploaded object SHA and update the remote ref last.

Exit gate: two Studio sessions cannot unknowingly overwrite each other's branch;
one is required to fetch/integrate after a stale push is rejected.

### Phase 4 - Clone and fast-forward pull

- Make clone initialize a real origin, HEAD, index, and repo root.
- Preserve the old import use case under an explicit spelling.
- Implement switch/checkout of branches with overwrite checks.
- Implement `pull --ff-only` as fetch plus atomic checkout.
- Apply remote deletions only when tracked and safe.

Exit gate: clone -> edit -> add -> commit -> push and fetch -> pull both behave
like their desktop Git equivalents for supported files.

### Phase 5 - Three-way merge

- Add bounded graph traversal and merge-base discovery.
- Add text merge, index stages, conflict display/resolution, merge commit, and
  abort.
- Add delete/modify and add/add cases before enabling merge as a pull policy.
- Keep rebase out until its sequencer can be persisted and aborted safely.

Exit gate: clean merges, conflicts, restart during conflict resolution, and abort
all preserve data and produce the expected commit graph.

### Phase 6 - Compatibility and polish

- Add stable `--porcelain` output and improve human status/log formatting.
- Add branch deletion, remote rename/remove, prune, and selected reset forms.
- Add bounded caching, ETag use, rate-limit diagnostics, and object GC telemetry.
- Update README, `/help`, MAP, examples, migration notes, and security guidance.

Exit gate: every advertised command has tests, help, recovery errors, and a clear
statement of differences from desktop Git.

## Verification matrix

Pure self-tests:

- Git object bytes and SHAs against desktop Git fixtures;
- all three script suffix mappings and Rojo `init` round trips;
- scripts nested beneath WorldModels, Models, Parts, Folders, and services;
- unsupported remote blobs preserved unchanged across a source-only commit;
- refusal to delete a script that owns non-script descendants;
- HEAD/index/worktree status combinations, including add-then-edit;
- ancestry, ahead/behind, merge bases, criss-cross bounds, and reachability;
- three-way merge success and every supported conflict shape;
- state generation recovery, migration, and object pruning; and
- redaction of PATs, access tokens, refresh tokens, device codes, and auth
  headers from all rendered errors.

Opt-in GitHub integration tests against disposable repositories:

- empty repository/root commit and normal push;
- public anonymous fetch and private authenticated fetch;
- default branches other than `main`;
- nested and Unicode paths, deletion, and more than one tree page/truncation;
- stale push, protected branch rejection, token expiry/revocation, and rate limit;
- interrupted upload before ref update; and
- SHA parity for blobs, trees, and commits returned by GitHub.

Studio acceptance tests:

- published and unpublished places, copied places, and multiple repo roots;
- a WorldModel used as the repo root and as an intermediate container;
- pull, switch, restore, status, add, commit, and diff affecting Source only;
- non-script descendants and container properties unchanged after every Git
  operation;
- plugin restart with staged changes, unpushed commits, and an active conflict;
- Team Create does not replicate credentials or repository internals;
- every DataModel mutation is one useful Ctrl+Z operation;
- a pull/switch failure changes neither instances nor repository state; and
- large places yield often enough to keep Studio responsive.

## Definition of done

The project may call this "authentic Git" for its supported surface when all of
the following are true:

- only ModuleScript, Script, and LocalScript Source is projected, while existing
  WorldModels and other containers work as ordinary directory paths without
  being versioned;
- `add` snapshots content and `commit` consumes only that snapshot;
- local commits are durable, offline-capable, and separate from push;
- status names staged, unstaged, untracked, ahead, behind, and conflict states
  from the correct comparisons;
- fetch is non-mutating, pull integrates, and push is lease-safe;
- clone configures a usable repository and honors the remote default branch;
- GitHub login is revocable, least-privilege, refreshable, and never leaks a
  credential;
- destructive worktree operations are preflighted, atomic, and undoable; and
- documentation clearly lists unsupported Git features and Roblox mapping limits.

## Primary references

- Git glossary (working tree and index): https://git-scm.com/docs/gitglossary
- `git status` state model: https://git-scm.com/docs/git-status
- `git add` index behavior: https://git-scm.com/docs/git-add
- GitHub App user device flow:
  https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
- GitHub Git blobs API: https://docs.github.com/en/rest/git/blobs
- GitHub Git trees API: https://docs.github.com/en/rest/git/trees
- GitHub Git commits API: https://docs.github.com/en/rest/git/commits
- GitHub Git refs API: https://docs.github.com/en/rest/git/refs
