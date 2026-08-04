# Claude Code for Roblox

A Roblox Studio plugin that puts an AI coding agent inside Studio. It talks to the
Anthropic Messages API over your Claude subscription (OAuth), and gives the model a
set of tools that treat the **DataModel as a filesystem** — `ls`, `cat`, `grep`,
`cd`, `edit`, `write`, and friends operate on Instances instead of files.

## Install

`main.lua` is the plugin **Script**; `main/` becomes its children, with each
subfolder a **Folder** instance and each `.lua` a **ModuleScript**. Build that
hierarchy into a `.rbxmx` in your Studio plugins folder (Rojo, or by hand).

Requires HTTP requests enabled (`Game Settings → Security → Allow HTTP Requests`).

`catalog` loads models through `game:GetObjects`, which needs no extra setting —
`LoadAsset`/`LoadAssetAsync` both gate on ownership, and the switch that lifts it
(`AssetService.AllowInsertFreeAssets`) is RobloxScriptSecurity, so a plugin can
neither read nor set it. The tradeoff is that **GetObjects does not sandbox**:
scripts inside a loaded model arrive live, where `LoadAssetAsync` would have
stripped their capabilities. Loads report their script count for that reason —
inspect before running anything.

## Use

1. Click the **Claude Code** toolbar button to open the widget.
2. `/login` → open the printed URL in a browser → `/code <pasted-code>`.
3. Type a message, or `/` for the command list.

**Enter** sends, **Shift+Enter** adds a line; the input grows to ~4 lines and
then scrolls.

### Copying text out

Roblox gives plugins [no clipboard API][clip] — nothing can write the clipboard
programmatically. The only route is a selectable field the user presses Ctrl+C
in, so that is what the console gives you:

- **Code blocks** and **plain console lines** (tool output, errors, `/sh`
  results) are `TextBox`es, not labels — select and copy them directly.
  **select all** focuses and selects a whole code block for you.
- **⧉ raw** on any reply swaps the rendered output for the raw markdown in one
  selectable box, and selects it. That is the way to take a whole answer.

Those boxes keep `TextEditable = true` and revert any edit, rather than using
`TextEditable = false`. The false setting is the obvious way to write a read-only
box and it does not work: the box stops taking focus, and with no focus there is
no selection to copy.

Selection cannot cross widgets in Roblox — each box is its own scope, so there is
no dragging from one paragraph into the next the way a text editor allows. The
raw toggle exists because of that limit, not alongside it.

Paragraphs stay non-selectable labels on purpose. They render through RichText,
and RichText selection indices map to the *raw* string — copying a bold word
would hand you `<b>word</b>`. Only blocks that are already verbatim are
selectable.

[clip]: https://devforum.roblox.com/t/allow-studio-plugins-to-copy-things-to-clipboard/638682

Slash commands: `/login` `/code` `/logout` `/status` `/model` `/settings` `/sh`
`/clear` `/help`. The ⚙ button opens model, effort, web-search, run-code and
system-prompt settings; they persist via `plugin:SetSetting`.

## Tools the model gets

| Tool | Payload | Notes |
|---|---|---|
| `bash` | a command line | pipes, `;` `&&` `\|\|`, newlines, `>` `>>`, heredocs, globs |
| `edit` / `multiedit` | unique substring swaps | atomic; one undo record per batch |
| `write` | whole `.Source` | |
| `run` | Luau source | **off by default**, plugin-permission level, no timeout |
| `catalog` | search / load Free Models | filtered to public-domain Models, ranked by takes; loads unsandboxed |

Path mapping: `/` = `game`, `/Workspace/Parts/Brick` = absolute, `.` `..` as usual.
Scripts are listed with a `.luau` suffix. `-type f` is a script, `-type d` is
anything else. Every mutation is wrapped in a `ChangeHistoryService` recording,
so **Ctrl+Z works**.

Not a shell interpreter: no variables, control flow, `$?`, command substitution
or environment. Anything needing real composition should use `run` rather than
growing a language in `Shell`. `/dev/null` and the stderr redirections are
supported to the extent they mean anything here — see Token conservation below.

## Layout

```
main.lua          plugin entry: widget, toolbar, input row, autocomplete, wiring
main/
  Commands.lua    slash commands — the glue, so it sits at the root
  agent/
    Claude.lua    Messages API client — SSE streaming over CreateWebStreamClient
    Agent.lua     conversation history + the streaming tool-use loop
    Tools.lua     tool registry — sorted, deduped, dispatches by name
    tools/        one file per tool: bash, edit, write, run, catalog
  fs/
    Fs.lua        path resolution, .Source access, undo recording, glob matching
    Props.lua     property names + default baselines, from the Roblox API dump
    Terminal.lua  the commands, as operations on the DataModel
    Shell.lua     the command line: tokenizer, pipes, redirection, heredocs
  ui/
    Theme.lua     palette, fonts, the `make(class, props)` helper
    Markdown.lua  Markdown → renderable blocks (Console draws them as GUI objects)
    Console.lua   scrolling output, streaming assistant bubble, tool-call lines
    Settings.lua  persisted prefs + the settings panel
  auth/
    Sha256.lua    PKCE hashing
    OAuth.lua     Anthropic OAuth + PKCE, token storage/refresh
```

Folders are Roblox Folders; a module's `script.Parent` is its own folder, so
**same-folder requires are just `script.Parent:WaitForChild("X")`**. Only five
files reach across folders at all — `main.lua`, `Commands.lua`, `agent/Agent.lua`
(→ ui), `fs/Shell.lua` (→ agent/Tools), `ui/Settings.lua` (→ agent/Claude). That
count is the point: if a sixth appears, the grouping is probably wrong.

Requires are Instance-based rather than [require-by-string][rbs]. String requires
do work in the engine, but Roblox supports **neither user-defined `.luaurc`
aliases nor a `@plugin` root alias**, so a plugin can only use relative `../`
paths — which encode depth in every file and break on a move, the opposite of
what the grouping is for. Revisit if a plugin alias ships.

[rbs]: https://devforum.roblox.com/t/introducing-require-by-string/3405078

Dependency flow is one-way, no cycles: `Fs`, `Props`, `Tools`, `Theme`, `Sha256`,
`OAuth` and `Claude` depend on nothing internal; `Shell → Fs, Tools`;
`Terminal → Fs, Props, Shell`; `Theme → Markdown → Console`; `Claude → Settings`;
`Agent` and `Commands` on top.

`Terminal` and `Shell` split on the seam that was already there: Terminal knows
how to *do* things to the DataModel, Shell knows how to read a line and work out
which of those to call. A new command is a `HANDLERS` entry in Shell; a new piece
of syntax is a change in Shell and nowhere else.

**Adding a tool is adding a file** in `tools/`, exporting
`{ name, description, input_schema, run(term, input) -> string }` (or an array of
those). The registry picks it up, `/help` lists it, and the shell knows to say
"that's a separate tool" if the model tries it as a command — no other file
changes. Tools are sorted by name because definitions render at the front of
every request and prompt caching is a prefix match: a reordered tool block
invalidates the system and conversation caches along with it.

## Token conservation

Context is the scarce resource: every turn resends the whole conversation, so a
tool that dumps 3000 lines once keeps costing for the rest of the session. The
techniques below are the ones Claude Code itself uses, and where this harness
stands against each.

| Technique | Here | Notes |
|---|---|---|
| Prompt caching with a moving breakpoint | ✅ | System + tools at 1h TTL, conversation at 5m. The whole prior history is a cache read (~0.1×) rather than a reprocess. |
| Search returns locations, not content | ✅ | `grep` returns `path:line: text`, `find` returns paths. You read only what you decided to read. |
| Capped tool output | ✅ | grep/find 100 matches, `cat` 1000 lines, `run` 40 lines, `catalog` 20 results. |
| Truncation that says how to get the rest | ✅ | A truncated `cat` names the paging command instead of leaving you to guess. |
| Paging instead of re-reading | ✅ | `head -n 1200 f \| tail -n 200` windows a file without a second full read. |
| Discarding output you didn't want | ✅ | `> /dev/null` runs a command and throws the result away — see below. |
| Parallel tool calls | ✅ | Several reads per turn instead of one, so history is resent fewer times. |
| Lean tool descriptions | ✅ | Deliberately near-empty: a model knows what `ls` does, it can't know this is a DataModel. |
| Errors as ordinary output | ✅ | No stderr means no second stream to plumb, and a failure costs one line. |
| **Automatic compaction** | ❌ | The real gap. `MAX_TURNS = 40` is a hard stop, not a summarisation — a long session grows until you `/clear`. |
| **Read offset/limit parameters** | ➖ | Covered by `head`/`tail` pipes rather than arguments on `cat`. Costs the model a turn to work out the first time. |

### `/dev/null`

On a real system `/dev/null` is a device file that discards everything written to
it. Here it is **a path the shell recognises, not an instance** — deliberately,
because a real Folder named `dev` would live in the place file forever, turn up
in every `find`, and sync to disk.

| Form | Behaviour |
|---|---|
| `cmd > /dev/null` | Runs `cmd`, discards the output. Useful for a mutation whose confirmation text you don't need. |
| `cmd 2> /dev/null` | Accepted and ignored — there is no stderr to redirect. |
| `cmd &> /dev/null` | Same as `> /dev/null`; there is only one stream. |
| `cmd 2>&1` | Accepted and ignored, for the same reason. |
| `cmd < /dev/null` | Not supported — there is no input redirection at all. |

## Self-tests

Run at startup in a background task, results go to the Output window:
`Sha256` (known vectors), `Markdown.selfTest()` (block parsing, inline escaping,
every streaming prefix leaves RichText balanced), `Terminal.selfTest()` (tokenizer,
flag parsing, globs, every command survives a bare invocation, catalog result
filtering and ranking), `Props.selfTest()` (API-dump schema, superclass walk,
serialization filter).
