# Roblox Studio → GitHub: Pure-Plugin Version Control (Deep Research)

## Why This Became Possible (The API Timeline)

The user's instinct is correct — this was essentially impossible five years ago, but several platform changes unlocked it:

| Year | Change | What It Enabled |
|---|---|---|
| **Mar 2020** | **Plugin HTTP Permissions** — plugins gained the ability to make `HttpService` requests independent of the game's "Allow HTTP Requests" setting, with per-domain user approval prompts【turn11fetch0】【turn5find0】 | Plugins could finally hit `api.github.com` / `github.com` directly |
| **Oct 2023** | **ScriptEditorService APIs** — `GetEditorSource()` and `UpdateSourceAsync()` decoupled the editor buffer from the `.Source` property, guaranteeing reliable reads/writes of script contents【turn7fetch0】 | Plugins could reliably capture and rewrite script source, even mid-edit |
| **2023–2025** | **HttpService hardening in Studio** — `RequestAsync` became the standard for plugins, supporting custom headers (`Authorization`, `Content-Type`), arbitrary methods (`PUT`, `DELETE`, `POST`), and binary-tolerant bodies【turn5find0】 | Full GitHub REST API + Git smart-HTTP protocol support |
| **2025** | **Script Sync (built-in beta)** — Studio's native script-to-disk sync, but critically **this still requires external Git** and doesn't help a pure-plugin workflow【turn12search1】【turn12search4】 | Confirmed the gap that pure plugins like RoGit/GitSync fill |

The key unlock was the 2020 plugin HTTP permission model: plugins stopped inheriting the game's HTTP whitelist and instead prompt the user once per domain (`github.com`, `api.github.com`), then persist that grant【turn11fetch0】.

---

## The Two Contenders: Head-to-Head

| | **RoGit** (officialmelon) | **GitSync** (Dynamo-rblx / Roller_Bott) |
|---|---|---|
| **Architecture** | Pure-Luau port of the **native Git smart-HTTP protocol** (pkt-line, packfiles, refs, deltas) | **GitHub REST API v3** client (`api.github.com/repos/.../contents/`) |
| **What it versions** | **Full Instance hierarchy** — Parts, CFrames, Colors, EnumItems, NumberSequences, scripts, properties (serialized to JSON, with GUID attributes for instance refs)【turn8fetch0】 | **Scripts only** (`Script`, `LocalScript`, `ModuleScript`), with a `-- @ScriptType:` metadata header prepended【turn2fetch0】【turn11fetch0】 |
| **Git commands** | `clone`, `status`, `add`, `commit`, `push`, `pull`, `branch`, `checkout`, `switch`, `diff`, `fetch`, `config` — a real subset of Git【turn2fetch0】 | Push, Pull, Delete, List Branches, Repository Viewer (GUI)【turn11fetch0】 |
| **Auth** | Basic Auth header (`username:token` base64) — prompts for credentials in-plugin, stores via `plugin:SetSetting()`【turn5fetch0】 | `Authorization: token <PAT>` header, PAT pasted into settings UI, stored via `plugin:SetSetting()`【turn11fetch0】 |
| **HTTP layer** | `HttpService:RequestAsync` with `Content-Type: application/x-git-upload-pack-request`, parses side-band-64k packfile streams manually【turn7fetch0】 | `HttpService:RequestAsync` with `PUT`/`DELETE` to the Contents API, JSON-encoded bodies【turn11fetch0】 |
| **Status (2026)** | Actively maintained (last commit May 2026, 29 commits, 9 releases)【turn2fetch0】 | Actively maintained (last commit Jan 2026, 86 commits)【turn7fetch1】 |
| **Maturity** | **Experimental** — author explicitly warns "can cause data loss" and "editing the repository directly via third party means may cause corruption"【turn2fetch0】 | **More stable** — confirmation popups, branch selection, undo-waypoint integration via `ChangeHistoryService`【turn2fetch0】 |
| **Repo** | `github.com/officialmelon/RoGit` | `github.com/Dynamo-rblx/Git-Sync-Plugin`【turn7fetch1】 |

---

## Deep Dive: RoGit (The Full Git Implementation)

RoGit is the closest thing to what you're describing — it's a **from-scratch Luau implementation of Git's wire protocol**, not a wrapper around the GitHub API. Reading the source confirms it speaks real Git:

**Protocol layer (`git_proto.lua`):** Implements pkt-line encoding/decoding (`0000` flush packets, hex-length-prefixed data packets), ref parsing, and packfile header/object parsing with offset-delta resolution【turn6fetch0】.

**Remote layer (`git_remote.lua`):** `discoverRefs()` does a `GET` to `https://<host>/<repo>.git/info/refs?service=git-upload-pack`, parses the ref advertisement, then `fetchPackfile()` sends a `POST` with `want <sha> side-band-64k ofs-delta` commands, reassembles the side-band channel streams into a full packfile buffer, and decompresses objects via its bundled zlib implementation【turn7fetch0】.

**Serialization (`instances.lua`):** Every Instance property type gets a JSON-safe representation — `CFrame` becomes `{pos, rX, rY, rZ}` vectors, `EnumItem` becomes `{"EnumType", "Value"}`, `Instance` references become GUIDs stored as attributes (`_rogit_id`), floats are rounded to 6 decimals to avoid SHA-1 jitter【turn8fetch0】.

**Auth (`requests.lua`):** On a `401`, it prompts for username/password in the plugin UI (works with a GitHub PAT as the password), base64-encodes them into a `Basic` Authorization header, and retries【turn5fetch0】.

**The catch:** The author labels it experimental and a hobby project, with known issues around branching, union support, and speed【turn2fetch0】. The README warns that mixing Studio-side and external edits to the same repo "may cause corruption and damage to your projects"【turn2fetch0】.

---

## Deep Dive: GitSync (The REST-API Approach)

GitSync takes the opposite approach: it uses **GitHub's Contents REST API**, which is dramatically simpler but limits what can be versioned.

**Push (`Interactions.lua`):** For each selected script, it constructs a path like `ServerScriptService/MainModule`, base64-encodes the source with a `-- @ScriptType:` header, and sends a `PUT` to `https://api.github.com/repos/<user>/<repo>/contents/<path>` with `{message, content, branch, sha}` — the standard "create or update file contents" endpoint【turn11fetch0】.

**Pull:** Lists repo contents recursively, recreates the folder structure in `workspace`, instantiates scripts of the correct class based on the metadata header【turn2fetch0】.

**Undo safety:** It wraps pushes/pulls in `ChangeHistoryService:SetWaypoint()` calls, so Studio's undo can revert structural changes — though not source modifications【turn2fetch0】.

**The catch:** It reads script contents via the legacy `.Source` property rather than `ScriptEditorService:GetEditorSource()` (I verified this in the source — `Functions.lua` uses `obj.Source` directly at lines 83, 246, 294)【turn13find0】. Roblox has warned that `.Source` won't always reflect the editor buffer for open scripts【turn7fetch0】, so it may miss unsaved changes if a script is open and mid-edit during a push. It also versions **only scripts** — no Parts, no properties, no UI hierarchy.

---

## Authentication: How It Works Without External APIs

Both plugins solve the "no external API" constraint the same way:

1. **You generate a GitHub PAT** (classic token with `repo` scope is sufficient)【turn1fetch0】.
2. **You paste it into the plugin's settings UI** inside Studio.
3. **The plugin stores it** via `plugin:SetSetting()` (persisted across Studio sessions, stored locally on your machine)【turn2fetch0】.
4. **On every request**, the token is attached as either `Authorization: token <PAT>` (GitSync) or `Authorization: Basic base64(user:token)` (RoGit).

**Why not OAuth?** GitHub's OAuth flow requires a browser redirect and a callback URL — neither of which can be done inside a Roblox Studio plugin window. The **device authorization flow** (`https://github.com/login/device`) theoretically could be driven via `HttpService` (it's just polling a REST endpoint), but neither plugin implements it, and GitHub requires device flow to be manually enabled per-app【turn3search10】. PAT-based Basic/Bearer auth is the pragmatic pure-plugin answer.

---

## Limitations & Common Pitfalls

**What still can't be done purely in-plugin:**
- **Binary assets** — `.rbxm` models, images, meshes, sounds. RoGit serializes properties but skips binary payload data; GitSync doesn't attempt it at all. Neither can push a `.rbxl` place file to GitHub as a meaningful diff.
- **Merge conflict resolution** — RoGit has `git diff` but no interactive merge tool; conflicts are likely to require manual cleanup.
- **Team Create simultaneity** — GitSync's own docs note that "Undo doesn't work on Source changes" and pulls are "strongly advised against" when folders are involved【turn2fetch0】.

**Security considerations:**
- Your PAT sits in Studio's plugin settings store — readable by any other plugin running in the same Studio session with sufficient permissions. Use a **fine-grained PAT scoped to specific repos only**, never a classic token with full account access.
- The HTTP permission prompt (the dialog asking "allow this plugin to access github.com?") is your only gate against a malicious plugin exfiltrating your token to a lookalike domain — read those prompts carefully【turn11fetch0】.

**Operational quirks:**
- GitSync prepends `-- @ScriptType: ...` metadata comments to every script; deleting these on GitHub's side causes scripts to be re-imported as server Scripts regardless of original class【turn2fetch0】.
- RoGit assigns GUID attributes (`_rogit_id`) to instances for reference tracking — these pollute your DataModel with hidden attributes【turn8fetch0】.
- Both plugins must be granted HTTP permission for `api.github.com` (GitSync) and/or `github.com` (RoGit) the first time they run.

---

## Other Tools You'll Encounter (And Why They Don't Qualify)

- **Rojo** — requires an external CLI binary and filesystem bridge; explicitly what you're avoiding【turn0search5】.
- **Script Sync (built-in, 2025)** — syncs scripts to local disk, but still requires you to run `git` externally; it's not a plugin-only workflow【turn12search1】【turn12search4】.
- **rbxsync (Smokestack-Games)** — full two-way sync with MCP support, but it's an external Node.js/desktop tool, not a pure plugin【turn12search7】.
- **Azul** — Studio-first two-way sync to filesystem; again requires external Git and a local watcher process【turn0search9】.
- **Frodevs VCS** — local version control inside Studio only; no GitHub integration【turn1fetch1】.

---

For a **pure Roblox plugin → GitHub push/pull with zero external dependencies**, your realistic options in August 2026 are:

- **RoGit** if you want true Git semantics (branches, diffs, full-instance versioning) and can tolerate experimental stability【turn0search18】.
- **GitSync** if you want reliable script-only sync with a friendlier GUI and REST-API stability【turn0search14】.

Both work because Roblox finally gave plugins independent HTTP permissions in 2020 and reliable script-source access in 2023 — the platform changes you suspected. Neither handles binary assets or provides real merge tooling, and both store your PAT locally in Studio, so scope that token tightly.

----------------

I have great leads. Let me now deep-dive into the actual repos and DevForum posts to get the technical details.
Let me now fetch the actual README content from the RoGit repos and the DevForum posts to understand the implementation details.
The GitHub page is loaded with metadata noise. Let me fetch the raw README directly.
Excellent! Both RoGit repos are extremely fresh (Feb 2026 and April 2026). Let me get more details and check the other plugins too.
The officialmelon/RoGit is fascinating - they've actually ported the **native git protocol over HTTPS** to Luau (not just GitHub REST API). Let me dig into the source code to verify.
This confirms it - **officialmelon/RoGit has a full Luau port of git protocol**: `hashlib.lua` (SHA1), `zlib.luau` (compression), `git_proto.lua`, `git_remote.lua`, `ini_parser.lua`. They actually compute blob SHAs in pure Luau and use the smart HTTP git protocol. Let me check the git_proto to confirm and look at the Frodevs VCS / Git Sync posts more deeply.
I have definitive proof - officialmelon/RoGit implements the **actual git smart HTTP protocol** in pure Luau (PKT-LINE parsing, SHA-1 hashing, zlib compression - all native, no external backend). Let me do a few more targeted searches to round out the research.
I have comprehensive research. Now let me also look at the officialmelon RoGit's plugin.lua and bash.lua briefly to confirm the in-Studio terminal/command UI, and look at any recent posts about API changes.
I have everything I need. Let me also load the docx skill so I can save a comprehensive research report alongside giving you the chat summary.
I have all the data I need. Let me update the todos and present the comprehensive research.
Here's the deep research. **Good news: the plugin you're describing now exists, and they're all from 2025-2026 — exactly the window where new Roblox APIs made it possible.**

---

## The Plugins (ranked by how well they match your spec)

### 🥇 1. `officialmelon/RoGit` — the closest possible match
**Repo:** https://github.com/officialmelon/RoGit · Created Feb 2026 · Last commit May 12, 2026

This is the only one that's **literally a pure-Luau port of git itself**, talking the native git smart-HTTP protocol. Not GitHub REST API — actual git.

I pulled the source and verified the implementation:
- `src/server/libs/git_proto.lua` — hand-rolled PKT-LINE parser/encoder (`decodePkt`, `encodePkt`, `flush`, delta-variant reader, `readU32BE`)
- `src/server/libs/git_remote.lua` — calls `GET /info/refs?service=git-upload-pack` and `POST /git-upload-pack` with `Content-Type: application/x-git-upload-pack-request` — that's the **actual git wire protocol**
- `src/server/libs/hashlib.lua` (57 KB) — SHA-1 in pure Luau so it can compute `blob <size>\0<content>` hashes
- `src/server/libs/zlib.luau` (60 KB) — pure Luau zlib inflate/deflate for packfiles
- `src/server/libs/requests.lua` — wraps `HttpService:RequestAsync`, handles 401 retry with Basic auth prompt, stores creds in `Plugin:SetSetting`
- `.git/` lives as a Folder instance in `ServerStorage` — uses Instances as a fake filesystem

**Commands supported:** `clone`, `status`, `add`, `commit -m`, `push`, `pull`, `checkout`, `switch`, `branch`, `diff`, `fetch`, `config`

**Two UIs:** a terminal/console ("Git Terminal") for power users and a "GitHub Desktop–esque" GUI panel. Works with **any** git host (GitHub, GitLab, Bitbucket, self-hosted) because it speaks the protocol, not GitHub's API.

**Caveats (author's own words):** "experimental, contains bugs, and *can* cause data loss." Hobby project, no stability guarantees. Currently **4 stars** — under the radar.

---

### 🥈 2. `Wharkk/RoGit` — the polished GitHub-native one
**Repo:** https://github.com/Wharkk/RoGit · Created April 16, 2026 · MIT license

Uses the **GitHub REST API** via `HttpService` (so still pure plugin, no external backend — but tied to GitHub specifically). This is the production-grade one.

What's notable (from the README I pulled):
- **Smart serialization:** object references (`PrimaryPart`, `Weld.Part0/Part1`, `Motor6D`, `Adornee`, `Attachment0/1`) survive round-trips via deferred resolution
- **Same-name siblings** auto-disambiguated with `__N` suffix
- **Path-unsafe names** (`Foo/Bar`, `CON`, `Weird*?"<>|:`) sanitized for git, restored on pull
- **`.meta.json` sidecars** for script attributes, tags, `Enabled`, `RunContext`
- **`_init` sentinel** pattern (like Rojo's `init`)
- **`.gitignore` via per-service `_gitignore` ModuleScript** with name patterns
- **Pull requests** (create + list open), **GitHub Actions** status (last 5 runs), **releases/tags**, **team activity feed**
- **Diff viewer** dock widget with full Luau tokenizer, line numbers, gutter, minimap
- Wrapped in `ChangeHistoryService` — one Ctrl+Z reverts an entire pull
- **Cold-pull gate:** first pull after connect forces a remote cache fetch so it never blind-overwrites
- Catppuccin Mocha themed UI, 3 dock widgets, 3 toolbar buttons

Serialized layout:
```
ServerScriptService/
  MyScript.server.luau
  MyScript.meta.json
  MyFolder/_init.json
  Wall.json
  Wall__2.json
README.md            ← from ServerStorage.README ModuleScript
```

**6 stars.** v1, known limitations: no CRLF normalization, conflict resolver is whole-file only (no per-line merge), dotted names like `v1.0.2` may break refs.

---

### 🥉 3. GitSync (by Roller_Bott) — the popular one
**DevForum:** https://devforum.roblox.com/t/git-sync-plugin-the-missing-link-between-github-and-roblox-studio/3539801 · Created March 9, 2025 · Last activity May 22, 2026

71 likes, 5,618 views, 40 posts — the most battle-tested of the three. On the Creator Store.

Also uses **GitHub REST API + PAT (classic, `repo` scope)** via HttpService. Pushes/pulls scripts and directories, create/switch branches. Less feature-rich than Wharkk's RoGit (no PRs, no Actions, no diff viewer) but more mature and has a written tutorial with screenshots. Author notes: **"Undo doesn't work on Source changes"** — a limitation Wharkk explicitly solved with `ChangeHistoryService`.

---

### ⚠️ 4. Frodevs VCS — different category
**DevForum:** https://devforum.roblox.com/t/frodevs-vcs-custom-version-control-system/3056171 · July 2024

**Not actually a GitHub plugin** — local-only version snapshots for individual scripts (save/revert/revert-to-last). I'm mentioning it only because it kept showing up in searches. Skip unless you want local-only snapshots with no remote.

---

## Why this is suddenly possible (the API changes you guessed at)

| API | Released | Why it matters |
|---|---|---|
| **`buffer` type** in Luau | Nov 2023 (beta), GA 2024 | Lets you parse binary packfiles and PKT-LINE frames without string-byte gymnastics. officialmelon/RoGit uses `buffer.readu8`/`buffer.len`/`buffer.fromstring` everywhere. Reported 95% networking-footprint reduction in some use cases. |
| **`ScriptEditorService:GetEditorSource` / `UpdateSourceAsync`** | Oct 2, 2023 | The old `Script.Source` property no longer reflects the live editor — plugins reading `Source` directly were silently broken. These new APIs are the *only* correct way to read/write script source from a plugin, and they're PluginSecurity. Both RoGits rely on them. |
| **`ChangeHistoryService` recordings** | Aug 2023 | Lets plugins wrap multi-step mutations in a single undoable recording. Wharkk uses this so a `Pull` is one Ctrl+Z. |
| **`HttpService:RequestAsync`** with arbitrary headers | mature but stable | Allows `Authorization`, `Content-Type: application/x-git-upload-pack-request`, etc. Required for both the GitHub REST API and the raw git protocol. |
| **`bit32` library** | mature | Required for the SHA-1 and zlib implementations (bit shifts, masks, etc.). |

The combination of `buffer` + `ScriptEditorService` is what unblocked it. Pre-2023, you couldn't reliably read script source *and* parse binary git packfiles from a plugin — that's why older attempts (the 2017 `einsteinK/Roblox-Version-Control` and the 2021 command-line plugin from the "What Is Git" DevForum post) all eventually died or required external tooling.

---

## Quick comparison

| | officialmelon/RoGit | Wharkk/RoGit | GitSync |
|---|---|---|---|
| **Created** | Feb 2026 | Apr 2026 | Mar 2025 |
| **Last activity** | May 12, 2026 | Apr 17, 2026 | May 22, 2026 |
| **Protocol** | Native git smart-HTTP | GitHub REST API | GitHub REST API |
| **Works with GitLab/Bitbucket** | ✅ Yes | ❌ GitHub only | ❌ GitHub only |
| **Auth** | Username/password or PAT | PAT (classic, `repo` scope) | PAT (classic, `repo` scope) |
| **Push/Pull/Branch/Commit** | ✅ | ✅ | ✅ |
| **Diff viewer** | console `git diff` | ✅ Full Luau tokenizer + minimap | ❌ |
| **Pull Requests** | ❌ | ✅ Create + list | ❌ |
| **GitHub Actions status** | ❌ | ✅ Last 5 runs | ❌ |
| **Releases/Tags** | ❌ | ✅ | ❌ |
| **Object reference round-trip** | partial | ✅ robust (PrimaryPart/Welds/Motor6D) | scripts only |
| **Undo (Ctrl+Z) safety** | partial | ✅ via ChangeHistoryService | ❌ warned "Undo doesn't work on Source changes" |
| **Conflict resolution** | planned | ✅ side-by-side (whole-file) | manual |
| **UI** | Terminal + Desktop GUI | Dock widgets (Catppuccin Mocha) | Dock widget |
| **License** | none | MIT | (Creator Store) |
| **Maturity** | hobby/experimental | v1, MIT, clean | most users, longest-running |
| **Stars** | 4 | 6 | n/a (71 DevForum likes) |

---

## My recommendation

- **Try Wharkk/RoGit first** — it's the most complete, properly licensed, has the cleanest UX, and solves the hard problems (object refs, undo safety, conflict UI). Install from the Roblox Creator Store or grab `RoGit.rbxmx` from the Releases page.
- **If you specifically need non-GitHub hosts (GitLab, Gitea, self-hosted)** — `officialmelon/RoGit` is the only option, and it's genuinely impressive engineering (full git protocol in Luau). But treat it as experimental, commit your work elsewhere first, and don't blame the author if it eats a place file.
- **Skip GitSync** unless you want the most-used / most-feedback-tested one — it's solid but Wharkk's feature set strictly dominates it.

Want me to also pull the actual install paths (Creator Store URLs), diff Wharkk's serialization module in detail, or write a quick proof-of-concept Luau script that does a single `git clone` via HttpService so you can see the wire protocol in action?